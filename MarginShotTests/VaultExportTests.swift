import XCTest
@testable import MarginShot

final class VaultExportTests: XCTestCase {
    func testPortableExportPreservesStoredNotesAndOriginalsAndExcludesRecoveryInternals() async throws {
        for encrypted in [false, true] {
            let fixture = try await ReliabilityVaultFixture()
            defer { try? fixture.remove() }
            fixture.defaults.set(encrypted, forKey: "privacyLocalEncryptionEnabled")
            try await fixture.createNote()
            let capture = CaptureStore(rootURL: fixture.root, userDefaults: fixture.defaults)
            let record = try capture.placeOriginal(Data("fixture original image".utf8), batchID: UUID(), notebookID: nil, pageNumber: 1)
            let originalURL = fixture.root.appendingPathComponent(record.rawPath)
            let internalURL = fixture.root.appendingPathComponent(".marginshot/unprepared/private-recovery.txt")
            try FileManager.default.createDirectory(at: internalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("recovery-only-content".utf8).write(to: internalURL)
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: zip) }
            try fixture.repository.withAccess {
                try ZipArchiveWriter.zipItem(at: fixture.root, to: zip, shouldKeepParent: true)
            }
            let data = try Data(contentsOf: zip)
            XCTAssertNotNil(data.range(of: Data("daily/atlas.md".utf8)))
            XCTAssertNotNil(data.range(of: try Data(contentsOf: fixture.noteURL)))
            XCTAssertNotNil(data.range(of: try Data(contentsOf: originalURL)))
            XCTAssertNil(data.range(of: Data(".marginshot".utf8)))
            XCTAssertNil(data.range(of: Data("recovery-only-content".utf8)))
            if encrypted { XCTAssertNil(data.range(of: Data("uniquecontent".utf8))) }
            else { XCTAssertNotNil(data.range(of: Data("uniquecontent".utf8))) }
        }
    }
}
