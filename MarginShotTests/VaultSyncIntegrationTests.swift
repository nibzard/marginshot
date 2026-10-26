import XCTest
@testable import MarginShot

final class VaultSyncIntegrationTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var rootURL: URL!
    private var persistenceController: PersistenceController!
    private var indexStore: VaultIndexStore!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "com.marginshot.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        testDefaults.set(OrganizationStyle.johnnyDecimal.rawValue, forKey: "organizationStyle")
        testDefaults.set(true, forKey: "organizationLinkingEnabled")
        testDefaults.set(false, forKey: "privacyLocalEncryptionEnabled")
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marginshot-test-\(UUID().uuidString)", isDirectory: true)
        persistenceController = PersistenceController(inMemory: true)
        try await persistenceController.load()
        indexStore = VaultIndexStore(rootURL: rootURL, persistenceController: persistenceController, userDefaults: testDefaults)
        try VaultBootstrapper.bootstrapIfNeeded(userDefaults: testDefaults, rootURL: rootURL)
    }

    override func tearDownWithError() throws {
        // This URL is created by this fixture; never enumerate or delete Documents/vault.
        if let rootURL { try FileManager.default.removeItem(at: rootURL) }
        if let defaultsSuiteName { testDefaults.removePersistentDomain(forName: defaultsSuiteName) }
        indexStore = nil
        persistenceController = nil
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

        let result = try VaultWriter.apply(input: input, userDefaults: testDefaults, rootURL: rootURL)
        let noteURL = rootURL.appendingPathComponent(result.notePath)
        let metadataURL = rootURL.appendingPathComponent(result.metadataPath)
        let entityURL = rootURL.appendingPathComponent("10_projects/Project-Atlas.md")

        XCTAssertEqual(result.notePath, "01_daily/\(dateString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entityURL.path))

        let noteContents = try VaultFileStore.readText(from: noteURL, userDefaults: testDefaults)
        XCTAssertTrue(noteContents.contains("Raw transcription"))
        let replayed = try VaultWriter.apply(input: input, userDefaults: testDefaults, rootURL: rootURL)
        XCTAssertEqual(replayed.notePath, result.notePath)
        XCTAssertEqual(try VaultFileStore.readText(from: noteURL, userDefaults: testDefaults), noteContents)
    }

    func testVaultApplyServiceCreatesNote() async throws {
        let content = "# QA Note\n\nBody\n"
        let operation = VaultFileOperation(
            action: .create,
            path: "01_daily/qa-note.md",
            content: content,
            noteMeta: nil
        )

        let summary = try await VaultApplyService.apply([operation], userDefaults: testDefaults, rootURL: rootURL, indexStore: indexStore, refreshDerivedPages: {})
        let noteURL = rootURL.appendingPathComponent("01_daily/qa-note.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertEqual(try VaultFileStore.readText(from: noteURL, userDefaults: testDefaults), content)
        XCTAssertEqual(summary.createdOrUpdated, ["01_daily/qa-note.md"])
        XCTAssertTrue(summary.deleted.isEmpty)
        let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
        let indexData = try VaultFileStore.readData(from: indexURL, userDefaults: testDefaults)
        let snapshot = try JSONDecoder().decode(IndexSnapshot.self, from: indexData)
        XCTAssertTrue(snapshot.notes.contains { $0.path == "01_daily/qa-note.md" })
    }

    func testBootstrapUsesInjectedPreferencesAndPreservesExistingContent() throws {
        let systemURL = rootURL.appendingPathComponent("_system/SYSTEM.md")
        try VaultFileStore.writeText("Custom rules", to: systemURL, userDefaults: testDefaults)
        testDefaults.set(OrganizationStyle.simple.rawValue, forKey: "organizationStyle")
        try VaultBootstrapper.bootstrapIfNeeded(userDefaults: testDefaults, rootURL: rootURL)
        XCTAssertEqual(try VaultFileStore.readText(from: systemURL, userDefaults: testDefaults), "Custom rules")
        for folder in VaultFolder.folderNames(style: .simple) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(folder).path))
        }
    }

    func testFolderSyncerCopiesVaultFiles() throws {
        let sourceURL = rootURL.appendingPathComponent("01_daily/sync-test.md")
        try "sync".write(to: sourceURL, atomically: true, encoding: .utf8)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        try FolderSyncer.syncVault(to: destinationURL, userDefaults: testDefaults, rootURL: rootURL)

        let copiedURL = destinationURL.appendingPathComponent("01_daily/sync-test.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        // FolderSyncer copies raw files (not via VaultFileStore), so read with testDefaults
        XCTAssertEqual(try VaultFileStore.readText(from: copiedURL, userDefaults: testDefaults), "sync")
        try "updated sync content".write(to: sourceURL, atomically: true, encoding: .utf8)
        try FolderSyncer.syncVault(to: destinationURL, userDefaults: testDefaults, rootURL: rootURL)
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "updated sync content")
        XCTAssertEqual(try String(contentsOf: copiedURL, encoding: .utf8), "updated sync content")
        try FolderSyncer.syncVault(to: destinationURL, userDefaults: testDefaults, rootURL: rootURL)
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "updated sync content")
        XCTAssertEqual(try String(contentsOf: copiedURL, encoding: .utf8), "updated sync content")
    }

}

private enum TestVaultHelper {
    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
