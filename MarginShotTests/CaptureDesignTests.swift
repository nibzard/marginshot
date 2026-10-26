import CoreData
import CryptoKit
import UIKit
import XCTest
@testable import MarginShot

final class CaptureDesignTests: XCTestCase {
    @MainActor
    func testShutterRequiresPermissionReadySessionAndNoSave() {
        let model = CaptureViewModel(enqueueProcessing: {})
        model.permissionState = .authorized
        for state: CameraSessionState in [.idle, .configuring, .unavailable, .interrupted, .failed] {
            model.sessionState = state
            XCTAssertFalse(model.canCapture)
        }
        model.sessionState = .ready
        XCTAssertTrue(model.canCapture)
        model.isProcessing = true
        XCTAssertFalse(model.canCapture)
        model.isProcessing = false
        model.permissionState = .denied
        XCTAssertFalse(model.canCapture)
    }

    @MainActor
    func testImportedPagesPreserveSelectedBytesBatchAndNotebookAcrossFailure() async throws {
        let fixture = try await ReliabilityVaultFixture()
        defer { try? fixture.remove() }
        var enqueued = 0
        let store = CaptureStore(rootURL: fixture.root, userDefaults: fixture.defaults)
        let model = CaptureViewModel(captureStore: store, enqueueProcessing: { enqueued += 1 })
        model.bind(context: fixture.controller.container.viewContext)
        model.ensureDefaultNotebookIfNeeded()
        let notebook = try XCTUnwrap(fixture.controller.container.viewContext.fetch(NotebookEntity.fetchRequest()).first)
        model.setSelectedNotebookID(notebook.id)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let png = try XCTUnwrap(image.pngData())
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        try await model.ingestImage(png)
        model.setSelectedNotebookID(UUID())
        do { try await model.ingestImage(Data("bad image".utf8)); XCTFail("Corrupt data must fail") } catch {}
        try await model.ingestImage(jpeg)
        let scans = try fixture.controller.container.viewContext.fetch(ScanEntity.fetchRequest()).sorted { $0.pageNumber!.intValue < $1.pageNumber!.intValue }
        XCTAssertEqual(scans.count, 2)
        XCTAssertEqual(scans[0].batch?.id, scans[1].batch?.id)
        XCTAssertEqual(scans[1].batch?.notebook?.id, notebook.id)
        XCTAssertTrue(scans[0].imagePath.hasSuffix("-raw.png"))
        XCTAssertTrue(scans[1].imagePath.hasSuffix("-raw.jpg"))
        for (scan, data) in zip(scans, [png, jpeg]) {
            XCTAssertEqual(try VaultFileStore.readData(from: fixture.root.appendingPathComponent(scan.imagePath), userDefaults: fixture.defaults), data)
            XCTAssertTrue(scan.processedImagePath?.hasSuffix(".jpg") == true)
        }
        XCTAssertNotNil(model.finishBatch())
        XCTAssertNil(model.finishBatch())
        XCTAssertEqual(enqueued, 1)
        let recovered = PersistenceController(inMemory: true)
        try await recovered.load()
        try store.recover(context: recovered.container.viewContext)
        XCTAssertEqual(try recovered.container.viewContext.fetch(ScanEntity.fetchRequest()).map(\.id).sorted { $0.uuidString < $1.uuidString }, scans.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    func testOnboardingConsentDoesNotChangeExistingPreference() {
        let suite = "consent-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ProcessingConsent.initialize(allowImages: false, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "privacySendImagesToLLM"))
        ProcessingConsent.initialize(allowImages: true, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "privacySendImagesToLLM"))
        defaults.set(true, forKey: "privacySendImagesToLLM")
        ProcessingConsent.initialize(allowImages: false, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "privacySendImagesToLLM"))
        XCTAssertNil(defaults.object(forKey: SyncDefaults.destinationKey))
    }
    @MainActor
    func testCameraDecodeFailureRetainsOriginalAndRetryableScan() async throws {
        let fixture = try await ReliabilityVaultFixture()
        defer { try? fixture.remove() }
        let model = CaptureViewModel(captureStore: CaptureStore(rootURL: fixture.root, userDefaults: fixture.defaults), enqueueProcessing: {})
        let context = fixture.controller.container.viewContext
        model.bind(context: context)
        model.ensureDefaultNotebookIfNeeded()
        let raw = Data("Undecodable camera result retained for recovery".utf8)
        do { try await model.ingestImage(raw, alreadySaving: true); XCTFail("Decoding must fail") } catch {}
        let scan = try XCTUnwrap(context.fetch(ScanEntity.fetchRequest()).first)
        XCTAssertEqual(scan.jobState, ProcessingJobState.needsAttention.rawValue)
        XCTAssertEqual(scan.status, ScanStatus.error.rawValue)
        XCTAssertEqual(try VaultFileStore.readData(from: fixture.root.appendingPathComponent(scan.imagePath), userDefaults: fixture.defaults), raw)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(model.scanCount, 1)
    }

}
