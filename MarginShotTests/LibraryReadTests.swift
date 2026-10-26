import CryptoKit
import XCTest
@testable import MarginShot

final class LibraryReadTests: XCTestCase {
    func testMissingCorruptIndexSearchAndFullReadPreserveNoteBytes() async throws {
        let fixture = try await ReliabilityVaultFixture()
        defer { try? fixture.remove() }
        try await fixture.createNote()
        let original = try Data(contentsOf: fixture.noteURL)
        let service = LibraryStore(root: fixture.root, defaults: fixture.defaults, controller: fixture.controller)
        try Data("corrupt".utf8).write(to: fixture.root.appendingPathComponent("_system/INDEX.json"))
        let notes = try await service.notes(query: "uniquecontent", limit: 1)
        XCTAssertEqual(notes.map(\.path), ["daily/atlas.md"])
        let empty = try await service.notes(query: "doesnotexist")
        XCTAssertTrue(empty.isEmpty)
        let full = try await service.content(path: "daily/atlas.md")
        XCTAssertTrue(full.markdown.contains("uniquecontent"))
        XCTAssertTrue(full.note.originalPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.noteURL), original)
        XCTAssertEqual(try fixture.index.libraryEntries(query: "", limit: 500).count, 1)
        _ = try await fixture.apply([
            VaultFileOperation(action: .create, path: "daily/second.md", content: "# Second note", noteMeta: nil),
            VaultFileOperation(action: .create, path: "daily/third.md", content: "# Third note", noteMeta: nil)
        ])
        let bounded = try await service.notes(query: "", limit: 2)
        let remainder = try await service.notes(query: "", limit: 2, offset: 2)
        XCTAssertEqual(bounded.count, 2)
        XCTAssertEqual(remainder.count, 1)
        XCTAssertEqual(Set((bounded + remainder).map(\.path)).count, 3)
        do { _ = try await service.content(path: "../secret.md"); XCTFail("Traversal must fail") } catch {}
        do { _ = try await service.content(path: "_system/SYSTEM.md"); XCTFail("Internal paths must fail") } catch {}
    }

    func testUnreadableContentIsAnErrorRatherThanAnEmptyLibrary() async throws {
        let fixture = try await ReliabilityVaultFixture()
        defer { try? fixture.remove() }
        try await fixture.createNote()
        try Data([0xff, 0xfe, 0xff]).write(to: fixture.noteURL)
        let service = LibraryStore(root: fixture.root, defaults: fixture.defaults, controller: fixture.controller)
        do { _ = try await service.notes(query: ""); XCTFail("Corrupt note must expose recovery") } catch {}
    }

    func testEncryptedReadsLeaveNoPlaintextSearchOrThumbnailFiles() async throws {
        let fixture = try await ReliabilityVaultFixture()
        defer { try? fixture.remove() }
        fixture.defaults.set(true, forKey: "privacyLocalEncryptionEnabled")
        try await fixture.createNote()
        let service = LibraryStore(root: fixture.root, defaults: fixture.defaults, controller: fixture.controller)
        let notes = try await service.notes(query: "uniquecontent")
        XCTAssertEqual(notes.count, 1)
        _ = try await service.content(path: "daily/atlas.md")
        XCTAssertTrue(VaultFileStore.isEncryptedFile(at: fixture.noteURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("_system/search.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("thumbnails").path))
    }

    @MainActor
    func testOnlyCommittedSourceMetadataAssociatesOriginalPages() async throws {
        let fixture = DesignFixture(state: "populated")
        try await fixture.prepare()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let store = LibraryStore(root: fixture.root, defaults: fixture.defaults, controller: fixture.controller)
        let note = try await store.content(path: "daily/field-notes.md")
        XCTAssertEqual(note.note.originalPaths.count, 2)
        let thumbnail = try await store.thumbnail(path: note.note.originalPaths[0])
        XCTAssertFalse(thumbnail.isEmpty)
        try VaultFileStore.writeText("# Unrelated note", to: fixture.root.appendingPathComponent("daily/unrelated.md"), userDefaults: fixture.defaults)
        let unrelated = try await store.content(path: "daily/unrelated.md")
        XCTAssertTrue(unrelated.note.originalPaths.isEmpty)
    }
}
