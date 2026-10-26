import CoreData
import XCTest
@testable import MarginShot

final class CapturePersistenceTests: XCTestCase {
    @MainActor
    func testMultiplePagesKeepOneBatchAndDoneQueuesIt() async throws {
        let controller = PersistenceController(inMemory: true)
        try await controller.load()
        let context = controller.container.viewContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(rootURL: root)
        let batchID = UUID()
        for page in 1...2 {
            let data = Data("original \(page)".utf8)
            let record = try store.placeOriginal(data, batchID: batchID, notebookID: nil, pageNumber: page)
            try store.persist(record, in: context)
            XCTAssertEqual(try VaultFileStore.readData(from: root.appendingPathComponent(record.rawPath)), data)
        }
        let batches = try context.fetch(BatchEntity.fetchRequest())
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.scans.count, 2)
        XCTAssertEqual(try store.finishBatch(batchID, in: context), batchID)
        XCTAssertEqual(batches.first?.status, BatchStatus.queued.rawValue)
    }
}
