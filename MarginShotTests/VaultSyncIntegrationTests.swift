import XCTest
@testable import MarginShot

final class VaultSyncIntegrationTests: XCTestCase {
    // Use a test-specific UserDefaults instance to avoid conflicts with app settings
    private let testDefaults: UserDefaults = {
        let userDefaults = UserDefaults(suiteName: "com.marginshot.tests")!
        userDefaults.set("simple", forKey: "organizationStyle")
        userDefaults.set(true, forKey: "organizationLinkingEnabled")
        userDefaults.set(false, forKey: "organizationTopicPagesEnabled")
        userDefaults.set(false, forKey: "privacyLocalEncryptionEnabled")
        return userDefaults
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TestVaultHelper.resetVault()
        try VaultBootstrapper.bootstrapIfNeeded(userDefaults: testDefaults)
    }

    override func tearDownWithError() throws {
        try TestVaultHelper.resetVault()
        // Clear test defaults
        testDefaults.removeObject(forKey: "organizationStyle")
        testDefaults.removeObject(forKey: "organizationLinkingEnabled")
        testDefaults.removeObject(forKey: "organizationTopicPagesEnabled")
        testDefaults.removeObject(forKey: "privacyLocalEncryptionEnabled")
        try super.tearDownWithError()
    }

    func testVaultWriterCreatesDailyNoteAndMetadata() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let dateString = TestVaultHelper.dateString(from: capturedAt)
        let input = VaultWriterInput(
            scanId: UUID(),
            batchId: UUID(),
            capturedAt: capturedAt,
            imagePath: "scans/2026-01-01/batch-1/page-001.jpg",
            processedImagePath: nil,
            transcript: TranscriptionPayload(
                rawTranscript: "Line 1",
                confidence: nil,
                uncertainSegments: nil,
                warnings: nil
            ),
            transcriptJSON: "{\"rawTranscript\":\"Line 1\"}",
            structured: StructurePayload(
                markdown: "# Entry\n\nNote body",
                noteMeta: NoteMeta(
                    title: "Entry",
                    summary: "Summary",
                    tags: ["tag"],
                    links: ["Project Atlas"]
                ),
                classification: Classification(folder: "01_daily", reason: nil),
                warnings: nil
            ),
            structuredJSON: "{\"markdown\":\"# Entry\"}"
        )

        let result = try VaultWriter.apply(input: input, userDefaults: testDefaults)
        let rootURL = try TestVaultHelper.vaultRootURL()
        let noteURL = rootURL.appendingPathComponent(result.notePath)
        let metadataURL = rootURL.appendingPathComponent(result.metadataPath)
        let entityURL = rootURL.appendingPathComponent("10_projects/Project-Atlas.md")

        XCTAssertEqual(result.notePath, "01_daily/\(dateString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entityURL.path))

        let noteContents = try VaultFileStore.readText(from: noteURL, userDefaults: testDefaults)
        XCTAssertTrue(noteContents.contains("Raw transcription"))
    }

    func testVaultApplyServiceCreatesNote() async throws {
        let content = "# QA Note\n\nBody\n"
        let operation = VaultFileOperation(
            action: .create,
            path: "01_daily/qa-note.md",
            content: content,
            noteMeta: nil
        )

        let summary = try await VaultApplyService.apply([operation], userDefaults: testDefaults)
        let rootURL = try TestVaultHelper.vaultRootURL()
        let noteURL = rootURL.appendingPathComponent("01_daily/qa-note.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertEqual(try VaultFileStore.readText(from: noteURL, userDefaults: testDefaults), content)
        XCTAssertEqual(summary.createdOrUpdated, ["01_daily/qa-note.md"])
        XCTAssertTrue(summary.deleted.isEmpty)
    }

    func testFolderSyncerCopiesVaultFiles() throws {
        let rootURL = try TestVaultHelper.vaultRootURL()
        let sourceURL = rootURL.appendingPathComponent("01_daily/sync-test.md")
        try "sync".write(to: sourceURL, atomically: true, encoding: .utf8)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        try FolderSyncer.syncVault(to: destinationURL, userDefaults: testDefaults)

        let copiedURL = destinationURL.appendingPathComponent("01_daily/sync-test.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        // FolderSyncer copies raw files (not via VaultFileStore), so read with testDefaults
        XCTAssertEqual(try VaultFileStore.readText(from: copiedURL, userDefaults: testDefaults), "sync")
    }
}

private enum TestVaultHelper {
    static func vaultRootURL() throws -> URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultBootstrapError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    static func resetVault() throws {
        let rootURL = try vaultRootURL()
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
    }

    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
