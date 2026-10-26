import CryptoKit
import XCTest
@testable import MarginShot

final class VaultRepositoryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var repository: VaultRepository!
    private enum Interruption: Error { case simulated }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repository-test-\(UUID().uuidString)", isDirectory: true)
        suite = "VaultRepositoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        repository = VaultRepository.register(rootURL: root, userDefaults: defaults, encryptionKey: SymmetricKey(size: .bits256))
        try VaultBootstrapper.bootstrapIfNeeded(userDefaults: defaults, rootURL: root)
    }

    override func tearDownWithError() throws {
        repository.checkpoint = nil
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        defaults.removePersistentDomain(forName: suite)
    }

    func testStaleExpectedRevisionLeavesNewerBytesUnchanged() throws {
        let path = "daily/note.md"
        let url = root.appendingPathComponent(path)
        try VaultFileStore.writeText("old", to: url, userDefaults: defaults)
        let revision = try repository.revision(for: path)
        try VaultFileStore.writeText("newer", to: url, userDefaults: defaults)
        XCTAssertThrowsError(try repository.transaction(expected: [path: revision]) {
            try VaultFileStore.writeText("stale proposal", to: url, userDefaults: self.defaults)
            return true
        })
        XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: defaults), "newer")
    }

    func testDuplicateOperationReturnsReceiptWithoutRepeatingMutation() throws {
        let url = root.appendingPathComponent("daily/note.md")
        let first: String = try repository.transaction(id: "stable-scan") {
            try VaultFileStore.writeText("one contribution", to: url, userDefaults: self.defaults)
            return "daily/note.md"
        }
        let second: String = try repository.transaction(id: "stable-scan") {
            XCTFail("A committed operation must not execute again")
            return "duplicate"
        }
        XCTAssertEqual(first, second)
        XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: defaults), "one contribution")
    }

    func testEveryPersistedCheckpointRecoversExactFilesAndRevisions() throws {
        for (index, point) in [VaultRepository.Checkpoint.prepared, .applied(0), .applied(1), .revisions, .committed].enumerated() {
            let paths = ["daily/\(index)-a.md", "daily/\(index)-b.md"]
            repository.checkpoint = { if $0 == point { throw Interruption.simulated } }
            XCTAssertThrowsError(try repository.transaction(id: "checkpoint-\(index)") {
                for (offset, path) in paths.enumerated() {
                    try VaultFileStore.writeText("content \(offset)", to: self.root.appendingPathComponent(path), userDefaults: self.defaults)
                }
                return paths
            })
            repository.checkpoint = nil
            let restarted = VaultRepository(rootURL: root, userDefaults: defaults)
            try restarted.recover()
            let receipt: [String] = try restarted.transaction(id: "checkpoint-\(index)") {
                XCTFail("Recovery must install the committed result receipt")
                return []
            }
            XCTAssertEqual(receipt, paths)
            for (offset, path) in paths.enumerated() {
                let url = root.appendingPathComponent(path)
                XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: defaults), "content \(offset)")
                let revision = try restarted.revisionState().revisions[path]
                XCTAssertEqual(revision?.revision, VaultRepository.hash(try Data(contentsOf: url)))
                XCTAssertEqual(revision?.operationID, "checkpoint-\(index)")
                XCTAssertEqual(revision?.deleted, false)
            }
        }
    }

    func testUnpreparedStagingDoesNotMutateLiveFiles() throws {
        let url = root.appendingPathComponent("daily/note.md")
        try VaultFileStore.writeText("original", to: url, userDefaults: defaults)
        repository.checkpoint = { if $0 == .staged { throw Interruption.simulated } }
        XCTAssertThrowsError(try repository.transaction(id: "not-prepared") {
            try VaultFileStore.writeText("uncommitted", to: url, userDefaults: self.defaults)
            return true
        })
        repository.checkpoint = nil
        try VaultRepository(rootURL: root, userDefaults: defaults).recover()
        XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: defaults), "original")
    }

    func testCoordinatedReaderFinishesPartialMultiFileOperation() throws {
        let a = root.appendingPathComponent("daily/a.md")
        let b = root.appendingPathComponent("daily/b.md")
        repository.checkpoint = { if $0 == .applied(0) { throw Interruption.simulated } }
        XCTAssertThrowsError(try repository.transaction {
            try VaultFileStore.writeText("A", to: a, userDefaults: self.defaults)
            try VaultFileStore.writeText("B", to: b, userDefaults: self.defaults)
            return true
        })
        repository.checkpoint = nil
        XCTAssertEqual(try VaultFileStore.readText(from: a, userDefaults: defaults), "A")
        XCTAssertEqual(try VaultFileStore.readText(from: b, userDefaults: defaults), "B")
    }

    func testFailedRecoveryPreservesBeforeAndAfterCopiesAndBlocksReaders() throws {
        let path = "daily/note.md"
        let url = root.appendingPathComponent(path)
        try VaultFileStore.writeText("before", to: url, userDefaults: defaults)
        repository.checkpoint = { if $0 == .prepared { throw Interruption.simulated } }
        XCTAssertThrowsError(try repository.transaction(id: "pending") {
            try VaultFileStore.writeText("intended", to: url, userDefaults: self.defaults)
            return true
        })
        repository.checkpoint = nil
        // An external writer changed the file while the app was terminated.
        try Data("external edit".utf8).write(to: url, options: .atomic)
        let restarted = VaultRepository(rootURL: root, userDefaults: defaults)
        XCTAssertThrowsError(try restarted.recover())
        XCTAssertThrowsError(try VaultFileStore.readText(from: url, userDefaults: defaults))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external edit")
        let operation = root.appendingPathComponent(".marginshot/operations/" + VaultRepository.hash(Data("pending".utf8)))
        XCTAssertEqual(try String(contentsOf: operation.appendingPathComponent("0.before"), encoding: .utf8), "before")
        XCTAssertEqual(try String(contentsOf: operation.appendingPathComponent("0.after"), encoding: .utf8), "intended")
        // Restoring the verified beforeimage permits deterministic recovery, without losing the external edit in this fixture.
        try Data("before".utf8).write(to: url, options: .atomic)
        try restarted.recover()
        XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: defaults), "intended")
    }

    func testDeletionRecoveryPersistsTombstone() throws {
        let url = root.appendingPathComponent("daily/deleted.md")
        try VaultFileStore.writeText("before", to: url, userDefaults: defaults)
        repository.checkpoint = { if $0 == .applied(0) { throw Interruption.simulated } }
        XCTAssertThrowsError(try repository.transaction(id: "delete") {
            try VaultRepository.removeItem(at: url)
            return true
        })
        repository.checkpoint = nil
        try repository.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try repository.revisionState().revisions["daily/deleted.md"], VaultRevision(revision: "deleted:delete", deleted: true, operationID: "delete"))
    }

    func testEncryptedStagingAndReceiptContainNoPlaintextContent() throws {
        defaults.set(true, forKey: "privacyLocalEncryptionEnabled")
        let url = root.appendingPathComponent("daily/private.md")
        try VaultFileStore.writeText("private before", to: url, userDefaults: defaults)
        repository.checkpoint = { if $0 == .prepared { throw Interruption.simulated } }
        XCTAssertThrowsError(try repository.transaction(id: "encrypted") {
            try VaultFileStore.writeText("private after", to: url, userDefaults: self.defaults)
            return "private result"
        })
        repository.checkpoint = nil
        let operation = root.appendingPathComponent(".marginshot/operations/" + VaultRepository.hash(Data("encrypted".utf8)))
        for name in ["0.before", "0.after"] {
            let data = try Data(contentsOf: operation.appendingPathComponent(name))
            XCTAssertTrue(VaultFileStore.isEncryptedData(data))
            XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "private"))
        }
        try repository.recover()
        XCTAssertTrue(VaultFileStore.isEncryptedFile(at: url))
        XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: defaults), "private after")
        let receipt = root.appendingPathComponent(".marginshot/receipts/" + VaultRepository.hash(Data("encrypted".utf8)))
        XCTAssertTrue(VaultFileStore.isEncryptedData(try Data(contentsOf: receipt)))
    }

    func testRejectsTraversalReservedPathsAndSymlinkEscapes() throws {
        for path in ["../escape.md", "/absolute.md", ".marginshot/intent.json", "daily//empty.md"] {
            XCTAssertThrowsError(try repository.validatedURL(path))
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try repository.validatedURL("escape/note.md"))
    }
}
