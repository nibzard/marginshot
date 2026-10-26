import XCTest
@testable import MarginShot

final class SyncCoordinatorTests: XCTestCase {
    private var root: URL!
    private var repository: VaultRepository!
    private var engine: RevisionSyncEngine!
    private var defaults: UserDefaults!
    private var suite: String!
    private enum Failure: Error { case simulated }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-test-\(UUID().uuidString)")
        suite = "SyncCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        repository = VaultRepository.register(rootURL: root, userDefaults: defaults)
        engine = RevisionSyncEngine(repository: repository)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        defaults.removePersistentDomain(forName: suite)
    }

    private func write(_ text: String, path: String = "daily/note.md") throws {
        try VaultFileStore.writeText(text, to: root.appendingPathComponent(path), userDefaults: defaults)
    }

    func testEditAfterEnumerationSkipsStaleSnapshotAndRetainsNewRevision() throws {
        try write("old")
        let item = try XCTUnwrap(engine.pending(destination: "A").first)
        try write("new")
        XCTAssertNil(try engine.snapshot(item))
        let pending = try XCTUnwrap(engine.pending(destination: "A").first)
        XCTAssertNotEqual(pending.revision, item.revision)
        XCTAssertEqual(pending.revision.revision, VaultRepository.hash(Data("new".utf8)))
    }

    func testEditDuringUploadAcknowledgesOnlyImmutableUploadedBytes() async throws {
        try write("old")
        let old = try XCTUnwrap(engine.pending(destination: "A").first)
        let destination = FakeDestination(identity: "A") { snapshot in
            XCTAssertEqual(snapshot.data, Data("old".utf8))
            try self.write("newer")
        }
        try await engine.sync(to: destination)
        let state = try repository.revisionState()
        XCTAssertEqual(state.acknowledgments["A"]?[old.path], old.revision.revision)
        let remaining = try engine.pending(destination: "A")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.revision.revision, VaultRepository.hash(Data("newer".utf8)))
    }

    func testTerminationBeforeAcknowledgmentRetainsPendingAndResends() async throws {
        try write("content")
        var requests = 0
        let destination = FakeDestination(identity: "A") { _ in requests += 1 }
        do {
            try await engine.sync(to: destination, beforeAcknowledgment: { throw Failure.simulated })
            XCTFail("Expected interruption")
        } catch Failure.simulated {}
        XCTAssertNil(try repository.revisionState().acknowledgments["A"])
        let restarted = RevisionSyncEngine(repository: VaultRepository(rootURL: root, userDefaults: defaults))
        XCTAssertEqual(try restarted.pending(destination: "A").count, 1)
        try await restarted.sync(to: destination)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(try restarted.pending(destination: "A").isEmpty)
    }

    func testPartialSuccessRetriesOnlyUnacknowledgedPaths() async throws {
        try write("A", path: "daily/a.md")
        try write("B", path: "daily/b.md")
        let failing = FakeDestination(identity: "A") { snapshot in
            if snapshot.item.path == "daily/b.md" { throw Failure.simulated }
        }
        do { try await engine.sync(to: failing); XCTFail("Expected partial failure") } catch Failure.simulated {}
        XCTAssertEqual(try engine.pending(destination: "A").map(\.path), ["daily/b.md"])
        var retried: [String] = []
        try await engine.sync(to: FakeDestination(identity: "A") { retried.append($0.item.path) })
        XCTAssertEqual(retried, ["daily/b.md"])
    }

    func testFailedDeletionRemainsPendingAndDoesNotDeleteUnrelatedDestinationPath() async throws {
        try write("content")
        try await engine.sync(to: FakeDestination(identity: "A") { _ in })
        try VaultRepository.removeItem(at: root.appendingPathComponent("daily/note.md"))
        let deletion = try XCTUnwrap(engine.pending(destination: "A").first)
        XCTAssertTrue(deletion.revision.deleted)
        do {
            try await engine.sync(to: FakeDestination(identity: "A") { _ in throw Failure.simulated })
            XCTFail("Expected deletion failure")
        } catch Failure.simulated {}
        XCTAssertEqual(try engine.pending(destination: "A"), [deletion])
        XCTAssertTrue(try engine.pending(destination: "new destination").isEmpty)
        try await engine.sync(to: FakeDestination(identity: "A") { XCTAssertNil($0.data) })
        XCTAssertTrue(try engine.pending(destination: "A").isEmpty)
    }

    func testLegacyManifestReconciliationRetainsDeletionScope() throws {
        let legacy = try engine.pending(destination: "A", legacyManifest: ["daily/old.md"])
        XCTAssertEqual(legacy.map(\.path), ["daily/old.md"])
        XCTAssertEqual(legacy.first?.revision.deleted, true)
        XCTAssertTrue(try engine.pending(destination: "B").isEmpty)
    }

    func testUploadIntentRetainsDeletionAfterTerminationBeforeAcknowledgment() async throws {
        try write("content")
        do {
            try await engine.sync(to: FakeDestination(identity: "A") { _ in }, beforeAcknowledgment: { throw Failure.simulated })
            XCTFail("Expected interruption")
        } catch Failure.simulated {}
        try VaultRepository.removeItem(at: root.appendingPathComponent("daily/note.md"))
        let restarted = RevisionSyncEngine(repository: VaultRepository(rootURL: root, userDefaults: defaults))
        let pending = try restarted.pending(destination: "A")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.revision.deleted, true)
    }

    func testDestinationSwitchCannotReuseOtherAcknowledgments() async throws {
        try write("content")
        try await engine.sync(to: FakeDestination(identity: "repo#main") { _ in })
        XCTAssertTrue(try engine.pending(destination: "repo#main").isEmpty)
        XCTAssertEqual(try engine.pending(destination: "repo#other").count, 1)
        XCTAssertEqual(try engine.pending(destination: "folder:/other").count, 1)
    }

    func testOfflineAndChargingDeferralSurviveCoordinatorRestart() async throws {
        try write("content")
        for _ in 0..<2 {
            let coordinator = SyncCoordinator(eligibility: { false }, run: { _ in XCTFail("Deferred work must not reach an adapter") })
            await coordinator.syncIfNeeded(trigger: .manual)
            XCTAssertEqual(try engine.pending(destination: "A").count, 1)
        }
        let coordinator = SyncCoordinator(eligibility: { true }, run: { _ in
            try await self.engine.sync(to: FakeDestination(identity: "A") { _ in })
        })
        await coordinator.syncIfNeeded(trigger: .wakeup)
        XCTAssertTrue(try engine.pending(destination: "A").isEmpty)
    }

    func testConcurrentTriggersClaimBusyBeforeEligibilityAndCoalesceWakeups() async throws {
        let gate = EligibilityGate()
        let runs = SyncRuns()
        let coordinator = SyncCoordinator(eligibility: { await gate.check() }, run: { _ in await runs.increment() })
        let task = Task { await coordinator.syncIfNeeded(trigger: .manual) }
        await gate.waitForFirstCheck()
        await coordinator.syncIfNeeded(trigger: .processing)
        await coordinator.syncIfNeeded(trigger: .applyToVault)
        await gate.release()
        await task.value
        let count = await runs.count
        XCTAssertEqual(count, 2)
        let checks = await gate.checks
        XCTAssertEqual(checks, 2)
    }

    func testFolderReplacementFailurePreservesSourceAndRejectsSourceOverlap() throws {
        try write("content")
        XCTAssertThrowsError(try FolderSyncer.syncVault(to: root, userDefaults: defaults, rootURL: root))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let blocked = destination.appendingPathComponent("daily/note.md", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data([0]).write(to: blocked.appendingPathComponent("unrelated"))
        XCTAssertThrowsError(try FolderSyncer.syncVault(to: destination, userDefaults: defaults, rootURL: root))
        XCTAssertEqual(try VaultFileStore.readText(from: root.appendingPathComponent("daily/note.md"), userDefaults: defaults), "content")
    }
}

private struct FakeDestination: VaultSyncDestination {
    let identity: String
    var legacyManifest: Set<String> { [] }
    let action: (VaultSyncSnapshot) async throws -> Void
    init(identity: String, action: @escaping (VaultSyncSnapshot) async throws -> Void) { self.identity = identity; self.action = action }
    func send(_ snapshot: VaultSyncSnapshot) async throws { try await action(snapshot) }
}

private actor SyncRuns {
    var count = 0
    func increment() { count += 1 }
}

private actor EligibilityGate {
    var checks = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Bool, Never>?
    func check() async -> Bool {
        checks += 1
        if checks > 1 { return true }
        entered?.resume(); entered = nil
        return await withCheckedContinuation { blocked = $0 }
    }
    func waitForFirstCheck() async {
        if checks > 0 { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { blocked?.resume(returning: true); blocked = nil }
}
