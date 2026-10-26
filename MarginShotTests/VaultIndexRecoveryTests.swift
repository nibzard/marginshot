import CryptoKit
import XCTest
@testable import MarginShot

final class VaultIndexRecoveryTests: XCTestCase {
    private var fixture: ReliabilityVaultFixture!
    override func setUp() async throws { fixture = try await ReliabilityVaultFixture() }
    override func tearDownWithError() throws { try fixture.remove() }

    func testMissingAndCorruptIndexesRebuildEquivalentContentAndMetadata() async throws {
        try await fixture.createNote()
        let before = await fixture.index.retrieveContextBundle(query: "Atlas")
        let bytes = try Data(contentsOf: fixture.noteURL)
        for corrupt in [false, true] {
            let json = fixture.root.appendingPathComponent("_system/INDEX.json")
            let sqlite = fixture.root.appendingPathComponent("_system/search.sqlite")
            if corrupt {
                try Data("corrupt".utf8).write(to: json, options: .atomic)
                try Data("corrupt".utf8).write(to: sqlite, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: json)
                try FileManager.default.removeItem(at: sqlite)
            }
            let rebuilt = await fixture.index.retrieveContextBundle(query: "Atlas")
            XCTAssertEqual(rebuilt.sources, before.sources)
            XCTAssertEqual(rebuilt.notes.map(\.body), before.notes.map(\.body))
            XCTAssertEqual(rebuilt.notes.first?.tags, ["project"])
            XCTAssertEqual(rebuilt.retrievalStatus, "ready")
            XCTAssertEqual(try Data(contentsOf: fixture.noteURL), bytes)
        }
    }

    func testMidUpdateFailureKeepsCommittedNoteAndRetriesIndexProgress() async throws {
        try await fixture.createNote()
        let oldProgress = try fixture.repository.revisionState().indexed
        fixture.index.rebuildCheckpoint = { if $0 == "indexJSON" { throw FixtureFailure.interrupted } }
        let revision = try fixture.repository.revision(for: "daily/atlas.md")
        let operation = VaultFileOperation(action: .update, path: "daily/atlas.md", content: "# Atlas\n\nNew durable text", noteMeta: nil, expectedRevision: revision)
        let summary = try await fixture.apply([operation])
        XCTAssertEqual(summary.createdOrUpdated, ["daily/atlas.md"])
        XCTAssertEqual(try VaultFileStore.readText(from: fixture.noteURL, userDefaults: fixture.defaults), "# Atlas\n\nNew durable text")
        XCTAssertEqual(try fixture.repository.revisionState().indexed, oldProgress)
        let failed = await fixture.index.retrieveContextBundle(query: "Atlas")
        XCTAssertEqual(failed.retrievalStatus, "indexUnavailable")
        fixture.index.rebuildCheckpoint = nil
        let recovered = await fixture.index.retrieveContextBundle(query: "Atlas")
        XCTAssertTrue(recovered.notes.first?.body?.contains("New durable text") == true)
        XCTAssertNotEqual(try fixture.repository.revisionState().indexed, oldProgress)
    }

    func testEncryptedRebuildLeavesNoPlaintextSearchArtifacts() async throws {
        fixture.defaults.set(true, forKey: "privacyLocalEncryptionEnabled")
        let search = fixture.root.appendingPathComponent("_system/search.sqlite")
        try Data("old plaintext search".utf8).write(to: search)
        try await fixture.createNote()
        try fixture.index.rebuildFromVault(force: true)
        XCTAssertTrue(VaultFileStore.isEncryptedFile(at: fixture.noteURL))
        XCTAssertTrue(VaultFileStore.isEncryptedFile(at: fixture.root.appendingPathComponent("_system/INDEX.json")))
        for name in ["search.sqlite", "search.sqlite-wal", "search.sqlite-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("_system/" + name).path))
        }
        let result = await fixture.index.retrieveContextBundle(query: "Atlas")
        XCTAssertEqual(result.sources.map(\.path), ["daily/atlas.md"])
        XCTAssertTrue(result.notes.first?.body?.contains("Body") == true)
    }

    func testEncryptionMigrationProtectsOldRecoveryArtifactsAndDefersPlaintextBackup() async throws {
        try await fixture.createNote()
        let operationID = "unprepared-before-encryption"
        fixture.repository.checkpoint = { if $0 == .staged { throw FixtureFailure.interrupted } }
        XCTAssertThrowsError(try fixture.repository.transaction(id: operationID) {
            try VaultFileStore.writeText("staged secret", to: self.fixture.root.appendingPathComponent("daily/staged.md"), userDefaults: self.fixture.defaults)
            return true
        })
        fixture.repository.checkpoint = nil
        fixture.defaults.set(true, forKey: "privacyLocalEncryptionEnabled")
        let engine = RevisionSyncEngine(repository: fixture.repository)
        let noteItem = try XCTUnwrap(engine.pending(destination: "folder:fixture").first { $0.path == "daily/atlas.md" })
        XCTAssertNil(try engine.snapshot(noteItem))
        try VaultEncryptionManager.prepareVault(rootURL: fixture.root, userDefaults: fixture.defaults)
        XCTAssertTrue(VaultFileStore.isEncryptedFile(at: fixture.noteURL))
        let staged = fixture.root.appendingPathComponent(".marginshot/operations/" + VaultRepository.hash(Data(operationID.utf8)) + "/0.after")
        XCTAssertTrue(VaultFileStore.isEncryptedFile(at: staged))
        let item = try XCTUnwrap(engine.pending(destination: "folder:fixture").first { $0.path == "daily/atlas.md" })
        XCTAssertNotEqual(item.revision, noteItem.revision)
        let snapshot = try XCTUnwrap(engine.snapshot(item))
        XCTAssertTrue(VaultFileStore.isEncryptedData(try XCTUnwrap(snapshot.data)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("_system/search.sqlite").path))
        let context = await fixture.index.retrieveContextBundle(query: "uniquecontent")
        XCTAssertEqual(context.sources.map(\.path), ["daily/atlas.md"])
    }

    func testValidEmptyIndexCannotHideDurableMarkdown() async throws {
        try await fixture.createNote()
        try VaultFileStore.writeText("{\"notes\":[]}", to: fixture.root.appendingPathComponent("_system/INDEX.json"), userDefaults: fixture.defaults)
        let result = await fixture.index.retrieveContextBundle(query: "Atlas")
        XCTAssertEqual(result.sources.map(\.path), ["daily/atlas.md"])
        let empty = await fixture.index.retrieveContextBundle(query: "unmatchableword")
        XCTAssertEqual(empty.retrievalStatus, "empty")
    }
}

enum FixtureFailure: Error { case interrupted }

final class ReliabilityVaultFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reliability-test-\(UUID().uuidString)")
    let suite = "ReliabilityVaultFixture.\(UUID().uuidString)"
    let defaults: UserDefaults
    let controller: PersistenceController
    let repository: VaultRepository
    let index: VaultIndexStore
    var noteURL: URL { root.appendingPathComponent("daily/atlas.md") }

    init() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(OrganizationStyle.simple.rawValue, forKey: "organizationStyle")
        repository = VaultRepository.register(rootURL: root, userDefaults: defaults, encryptionKey: SymmetricKey(size: .bits256))
        controller = PersistenceController(inMemory: true)
        try await controller.load()
        index = VaultIndexStore(rootURL: root, persistenceController: controller, userDefaults: defaults)
        try VaultBootstrapper.bootstrapIfNeeded(userDefaults: defaults, rootURL: root)
    }
    func createNote() async throws {
        _ = try await apply([VaultFileOperation(action: .create, path: "daily/atlas.md", content: "# Atlas\n\nBody and uniquecontent", noteMeta: NoteMeta(title: "Atlas", summary: "A project", tags: ["project"], links: []))])
    }
    func apply(_ operations: [VaultFileOperation]) async throws -> VaultApplySummary {
        try await VaultApplyService.apply(operations, userDefaults: defaults, rootURL: root, indexStore: index, refreshDerivedPages: {})
    }
    func remove() throws {
        index.rebuildCheckpoint = nil
        try FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
