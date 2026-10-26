import CoreData
import XCTest
@testable import MarginShot

final class ProcessingRecoveryTests: XCTestCase {
    private var root: URL!
    private var store: CaptureStore!
    private enum Interruption: Error { case simulated }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-test-\(UUID().uuidString)")
        store = CaptureStore(rootURL: root)
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }

    func testCapturePlacementAndMetadataCheckpointsRecoverOneOriginalAndScan() async throws {
        for (index, point) in [CaptureStore.Checkpoint.placed, .metadataSaved].enumerated() {
            let controller = PersistenceController(inMemory: true)
            try await controller.load()
            let context = controller.container.newBackgroundContext()
            let batchID = UUID()
            let scanID = UUID()
            let original = Data("original \(index)".utf8)
            store.checkpoint = { if $0 == point { throw Interruption.simulated } }
            XCTAssertThrowsError(try {
                let record = try store.placeOriginal(original, batchID: batchID, notebookID: nil, pageNumber: 1, scanID: scanID)
                try store.persist(record, in: context)
            }())
            store.checkpoint = nil
            let restarted = CaptureStore(rootURL: root)
            try restarted.recover(context: context)
            try restarted.recover(context: context)
            let captureRoot = try XCTUnwrap(root)
            try context.performAndWait {
                let request = ScanEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", scanID as CVarArg)
                let scans = try context.fetch(request)
                XCTAssertEqual(scans.count, 1)
                let scan = try XCTUnwrap(scans.first)
                XCTAssertEqual(scan.batch?.id, batchID)
                XCTAssertEqual(scan.batch?.status, BatchStatus.queued.rawValue)
                XCTAssertEqual(scan.jobState, ProcessingJobState.pending.rawValue)
                XCTAssertEqual(scan.jobCheckpoint, "original")
                XCTAssertEqual(try VaultFileStore.readData(from: captureRoot.appendingPathComponent(scan.imagePath)), original)
            }
        }
    }

    func testFailedMetadataThenAnotherPageDoesNotOverwriteFirstOriginal() throws {
        let batchID = UUID()
        let first = try store.placeOriginal(Data("first".utf8), batchID: batchID, notebookID: nil, pageNumber: 1)
        let second = try store.placeOriginal(Data("second".utf8), batchID: batchID, notebookID: nil, pageNumber: 1)
        XCTAssertNotEqual(first.rawPath, second.rawPath)
        XCTAssertEqual(try VaultFileStore.readText(from: root.appendingPathComponent(first.rawPath)), "first")
        XCTAssertEqual(try VaultFileStore.readText(from: root.appendingPathComponent(second.rawPath)), "second")
    }

    func testStartupRecoversRunningWorkAndPreservesStructuredAndFiledCheckpoints() async throws {
        let controller = PersistenceController(inMemory: true)
        try await controller.load()
        let context = controller.container.newBackgroundContext()
        try context.performAndWait {
            let batch = BatchEntity(context: context)
            batch.id = UUID(); batch.createdAt = Date(); batch.status = BatchStatus.processing.rawValue
            for status in [ScanStatus.transcribing, .structured, .filed] {
                let scan = ScanEntity(context: context)
                scan.id = UUID(); scan.createdAt = Date(); scan.status = status.rawValue
                scan.imagePath = "scans/\(scan.id).jpg"; scan.processedImagePath = "scans/processed.jpg"
                scan.batch = batch; scan.jobState = ProcessingJobState.running.rawValue
                scan.structuredJSON = status == .structured ? "persisted output" : nil
            }
            try context.save()
        }
        try ProcessingJobStore.recover(context: context)
        try ProcessingJobStore.recover(context: context)
        try context.performAndWait {
            let scans = try context.fetch(ScanEntity.fetchRequest())
            XCTAssertEqual(scans.count, 3)
            XCTAssertEqual(scans.filter { $0.status == ScanStatus.captured.rawValue }.first?.jobCheckpoint, "inputReady")
            XCTAssertEqual(scans.filter { $0.status == ScanStatus.structured.rawValue }.first?.structuredJSON, "persisted output")
            XCTAssertEqual(scans.filter { $0.status == ScanStatus.filed.rawValue }.first?.jobState, ProcessingJobState.complete.rawValue)
        }
    }

    func testCancellationOnLastStructuredScanPreservesCheckpoint() async throws {
        let controller = PersistenceController(inMemory: true)
        try await controller.load()
        let context = controller.container.newBackgroundContext()
        try context.performAndWait {
            let scan = ScanEntity(context: context)
            scan.id = UUID(); scan.createdAt = Date(); scan.imagePath = "scans/original.jpg"
            scan.status = ScanStatus.structured.rawValue; scan.structuredJSON = "durable output"
            scan.jobCheckpoint = "structured"
            ProcessingJobStore.pause(scan: scan, category: "cancellation")
            try context.save()
            XCTAssertEqual(scan.status, ScanStatus.structured.rawValue)
            XCTAssertEqual(scan.jobState, ProcessingJobState.paused.rawValue)
            XCTAssertEqual(scan.jobCheckpoint, "structured")
            XCTAssertEqual(scan.structuredJSON, "durable output")
        }
    }

    func testNoteCommitBeforeJobCompletionReplaysWithoutDuplicateContribution() async throws {
        let suite = "ProcessingRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(OrganizationStyle.johnnyDecimal.rawValue, forKey: "organizationStyle")
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PersistenceController(inMemory: true)
        try await controller.load()
        let context = controller.container.newBackgroundContext()
        let captureStore = CaptureStore(rootURL: root, userDefaults: defaults)
        let record = try captureStore.placeOriginal(Data("original".utf8), batchID: UUID(), notebookID: nil, pageNumber: 1)
        try captureStore.persist(record, in: context)
        let transcript = TranscriptionPayload(rawTranscript: "original words", confidence: nil, uncertainSegments: nil, warnings: nil)
        let structured = StructurePayload(markdown: "# Entry\n\nBody", noteMeta: NoteMeta(title: "Entry", summary: nil, tags: nil, links: nil), classification: Classification(folder: "01_daily", reason: nil), warnings: nil)
        let input = VaultWriterInput(scanId: record.scanID, batchId: record.batchID, capturedAt: record.createdAt, imagePath: record.rawPath, processedImagePath: nil, transcript: transcript, transcriptJSON: nil, structured: structured, structuredJSON: nil)
        let scanID = try context.performAndWait {
            let scan = try XCTUnwrap(context.fetch(ScanEntity.fetchRequest()).first)
            scan.status = ScanStatus.structured.rawValue
            scan.jobCheckpoint = "structured"
            scan.structuredJSON = String(data: try JSONEncoder().encode(structured), encoding: .utf8)
            scan.transcriptJSON = String(data: try JSONEncoder().encode(transcript), encoding: .utf8)
            try context.save()
            return scan.objectID
        }
        let committed = try VaultWriter.apply(input: input, userDefaults: defaults, rootURL: root)
        let note = root.appendingPathComponent(committed.notePath)
        let bytes = try Data(contentsOf: note)
        try captureStore.recover(context: context)
        let index = VaultIndexStore(rootURL: root, persistenceController: controller, userDefaults: defaults)
        let queue = ProcessingQueue(persistenceController: controller, rootURL: root, userDefaults: defaults, indexStore: index, refreshDerivedPages: { _ in })
        let success = await queue.fileStructuredScan(objectID: scanID, context: context, writerInput: input)
        XCTAssertTrue(success)
        let replayed = await queue.fileStructuredScan(objectID: scanID, context: context, writerInput: input)
        XCTAssertTrue(replayed)
        XCTAssertEqual(try Data(contentsOf: note), bytes)
        try context.performAndWait {
            let scan = try XCTUnwrap(context.existingObject(with: scanID) as? ScanEntity)
            XCTAssertEqual(scan.status, ScanStatus.filed.rawValue)
            XCTAssertEqual(scan.jobState, ProcessingJobState.complete.rawValue)
        }
    }

    func testTranscriptionAndOrganizationCheckpointsResumeWithoutRepeatingImageUpload() async throws {
        for stopStage in ["transcribed", "organized"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RecoveryProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel(); RecoveryProtocol.handler = nil }
            var requests = 0
            let transcript = "{\"rawTranscript\":\"words\"}"
            let structure = "{\"markdown\":\"# Entry\\nBody\",\"noteMeta\":{\"title\":\"Entry\"},\"classification\":{\"folder\":\"01_daily\"}}"
            RecoveryProtocol.handler = {
                requests += 1
                let text = requests == 1 ? transcript : structure
                return try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])
            }
            let configuration = GeminiConfiguration(apiKey: "fixture", model: "fixture", baseURL: URL(string: "https://fixture.invalid")!, timeout: 1, maxRetries: 0, minBackoff: 0, maxBackoff: 0)
            let client = GeminiClient(configuration: configuration, session: session, allowsImageUploads: { true })
            let context = ProcessingContextSnapshot(systemRules: "", indexJSON: nil, structureText: nil, organizationStyle: .johnnyDecimal, linkingEnabled: false)
            let input = ScanProcessingInput(imageData: Data([0]), mimeType: "image/jpeg")
            var saved: ProcessingCheckpoint?
            do {
                _ = try await ScanProcessingPipeline.process(input: input, mode: .best, client: client, context: context, saveCheckpoint: { checkpoint in
                    saved = checkpoint
                    if checkpoint.stage == stopStage { throw Interruption.simulated }
                })
                XCTFail("Expected interruption after durable checkpoint")
            } catch Interruption.simulated {} catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertEqual(saved?.stage, stopStage)
            let requestsBeforeResume = requests
            let resumedClient = GeminiClient(configuration: configuration, session: session, allowsImageUploads: { false })
            let result = try await ScanProcessingPipeline.process(input: input, mode: .best, client: resumedClient, context: context, checkpoint: saved)
            XCTAssertEqual(result.transcript.rawTranscript, "words")
            XCTAssertEqual(result.structured.noteMeta.title, "Entry")
            XCTAssertEqual(requests - requestsBeforeResume, stopStage == "transcribed" ? 2 : 1)
        }
    }

    func testV1MigrationPreservesIdentitiesImageHashAndFiledResult() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("fixture.sqlite")
        let legacy = PersistenceController(storeURL: database, legacySchema: true)
        try await legacy.load()
        let batchID = UUID(), scanID = UUID(), noteID = UUID()
        let image = root.appendingPathComponent("original.jpg")
        let bytes = Data("unaltered original".utf8)
        try bytes.write(to: image)
        let context = legacy.container.newBackgroundContext()
        try context.performAndWait {
            let batch = BatchEntity(context: context)
            batch.id = batchID; batch.createdAt = Date(); batch.status = BatchStatus.processing.rawValue
            let scan = ScanEntity(context: context)
            scan.id = scanID; scan.createdAt = Date(); scan.status = ScanStatus.filed.rawValue
            scan.imagePath = "original.jpg"; scan.batch = batch
            let note = NoteEntity(context: context)
            note.id = noteID; note.path = "daily/existing.md"; note.title = "Existing"
            note.createdAt = Date(); note.updatedAt = Date()
            try context.save()
        }
        for persistentStore in legacy.container.persistentStoreCoordinator.persistentStores {
            try legacy.container.persistentStoreCoordinator.remove(persistentStore)
        }
        let migrated = PersistenceController(storeURL: database)
        try await migrated.load()
        let migratedContext = migrated.container.newBackgroundContext()
        try ProcessingJobStore.recover(context: migratedContext)
        try migratedContext.performAndWait {
            let scan = try XCTUnwrap(migratedContext.fetch(ScanEntity.fetchRequest()).first)
            XCTAssertEqual(scan.id, scanID)
            XCTAssertEqual(scan.batch?.id, batchID)
            XCTAssertEqual(scan.imagePath, "original.jpg")
            XCTAssertEqual(scan.status, ScanStatus.filed.rawValue)
            XCTAssertEqual(scan.jobState, ProcessingJobState.complete.rawValue)
            XCTAssertEqual(try migratedContext.fetch(NoteEntity.fetchRequest()).first?.id, noteID)
        }
        XCTAssertEqual(VaultRepository.hash(try Data(contentsOf: image)), VaultRepository.hash(bytes))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("v1-backup") })
    }
}

private final class RecoveryProtocol: URLProtocol {
    static var handler: (() -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.handler!()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
