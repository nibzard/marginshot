import CoreData
import CryptoKit
import UIKit
import SwiftUI

#if DEBUG
/// Explicitly opted-in Debug fixtures. No normal recovery, credentials, or workers run here.
final class DesignFixture {
    static let current: DesignFixture? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-design-fixture"), arguments.indices.contains(index + 1) else { return nil }
        return DesignFixture(state: arguments[index + 1])
        #else
        return nil
        #endif
    }()

    let state: String
    let root: URL
    let defaults: UserDefaults
    let controller: PersistenceController

    init(state: String) {
        self.state = state
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("design-fixture-\(id)/vault")
        defaults = UserDefaults(suiteName: "MarginShot.DesignFixture.\(id)")!
        defaults.set(state != "onboarding", forKey: "hasCompletedOnboarding")
        if state != "onboarding" { defaults.set(false, forKey: "privacySendImagesToLLM") }
        defaults.set(false, forKey: "processingAutoProcessInbox")
        defaults.set("off", forKey: SyncDefaults.destinationKey)
        controller = PersistenceController(inMemory: true)
    }

    @MainActor
    func prepare() async throws {
        try await controller.load()
        if state == "encrypted" {
            defaults.set(true, forKey: "privacyLocalEncryptionEnabled")
            VaultRepository.register(rootURL: root, userDefaults: defaults, encryptionKey: SymmetricKey(size: .bits256))
        }
        try VaultBootstrapper.bootstrapIfNeeded(userDefaults: defaults, rootURL: root)
        let context = controller.container.viewContext
        let notebook = NotebookEntity(context: context)
        notebook.id = UUID()
        notebook.name = "Field notes and ideas for a more thoughtful everyday life"
        notebook.isDefault = true
        notebook.createdAt = Date()
        try context.save()
        if !["empty", "onboarding"].contains(state) {
            let text = "# A quieter way to collect ideas and turn notebook pages into useful work\n\nA walk through the city led to three observations about attention, space, and the way we keep our ideas.\n\n## Next steps\n\n- Collect examples from the neighborhood.\n- Leave room for a slower morning.\n\n## Raw transcription\n\nKeep the original words. Notice what makes a place feel welcoming."
            try VaultFileStore.writeText(text, to: root.appendingPathComponent("daily/field-notes.md"), userDefaults: defaults)
            let store = CaptureStore(rootURL: root, userDefaults: defaults)
            let batch = UUID()
            for page in 1...2 {
                let record = try store.placeOriginal(Self.pageImage(), batchID: batch, notebookID: notebook.id, pageNumber: page)
                try store.persist(record, in: context)
                if !["processing", "paused", "failed"].contains(state) {
                    let transcript = TranscriptionPayload(rawTranscript: "Notice what makes a place feel welcoming.", confidence: 0.95, uncertainSegments: nil, warnings: nil)
                    let structured = StructurePayload(markdown: text, noteMeta: NoteMeta(title: "A quieter way to collect ideas and turn notebook pages into useful work", summary: "Attention, space, and everyday ideas.", tags: [], links: []), classification: Classification(folder: "daily", reason: nil), warnings: nil)
                    let metadata = ScanMetadata(scanId: record.scanID.uuidString, batchId: batch.uuidString, capturedAt: ISO8601DateFormatter().string(from: Date()), imagePath: record.rawPath, processedImagePath: nil, notePath: "daily/field-notes.md", noteTitle: "Field notes", transcript: transcript, structured: structured, transcriptJSON: nil, structuredJSON: nil)
                    try VaultFileStore.writeData(JSONEncoder().encode(metadata), to: root.appendingPathComponent(VaultScanStore.metadataPath(for: record.rawPath)), userDefaults: defaults)
                }
            }
            for scan in try context.fetch(ScanEntity.fetchRequest()) {
                let pending = ["processing", "paused", "failed"].contains(state)
                scan.batch?.status = pending ? BatchStatus.queued.rawValue : BatchStatus.done.rawValue
                scan.status = pending ? ScanStatus.captured.rawValue : ScanStatus.filed.rawValue
                scan.jobState = pending ? (state == "processing" ? "running" : (state == "paused" ? "paused" : "needsAttention")) : "complete"
                scan.jobFailure = state == "paused" ? "imageUploadsDisabled" : "invalidImage"
            }
            try context.save()
        }
    }

    static func pageImage() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800))
        return renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            ("Field notes\n\nNotice what makes a place welcoming.\n\nLeave room for a slower morning." as NSString).draw(at: CGPoint(x: 50, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.label])
        }
    }

    @MainActor
    func captureModel() -> CaptureViewModel {
        let model = CaptureViewModel(captureStore: CaptureStore(rootURL: root, userDefaults: defaults), enqueueProcessing: {})
        if state == "saving" { model.isProcessing = true; model.statusText = "Saving page…" }
        return model
    }
}

/// A single seam used by presentation code; production retains its existing defaults.
enum PresentationDefaults {
    static var current: UserDefaults { DesignFixture.current?.defaults ?? .standard }
}

struct DesignFixtureRoot: View {
    let fixture: DesignFixture
    @State private var ready = false
    @State private var error: String?

    private var designTextSize: DynamicTypeSize {
        switch ProcessInfo.processInfo.environment["DESIGN_TEXT_SIZE"] {
        case "xxxl": return .xxxLarge
        case "accessibility": return .accessibility3
        default: return .large
        }
    }

    var body: some View {
        Group {
            if ready {
                ContentView()
                    .environment(\.managedObjectContext, fixture.controller.container.viewContext)
                    .defaultAppStorage(fixture.defaults)
            } else if let error {
                Text(error)
            } else {
                ProgressView("Preparing isolated fixture…")
            }
        }
        .themed()
        .preferredColorScheme(ProcessInfo.processInfo.environment["DESIGN_APPEARANCE"] == "dark" ? .dark : .light)
        .dynamicTypeSize(designTextSize)
        .task {
            do {
                try await fixture.prepare()
                ready = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension DesignFixture {
    @MainActor
    func chatModel() -> ChatViewModel {
        let model = ChatViewModel()
        model.readiness = state == "empty" ? .noNotes : (state == "setup" ? .setup : .ready)
        let answer = "Your notes explore how attention changes the way a place feels. You noticed that welcoming spaces leave room for pauses and small conversations.\n\nThe next step is to collect neighborhood examples and protect a slower morning. The original pages are available from the source below, so you can check the wording before using these ideas.\n\nA useful experiment would be to record one observation each day, then compare the patterns at the end of the week."
        let sources = [ContextSource(path: "daily/field-notes.md", title: "Field notes")]
        if ["populated", "encrypted", "stale"].contains(state) {
            var operations: [VaultFileOperation] = []
            if state == "stale" {
                operations = [VaultFileOperation(action: .update, path: "daily/field-notes.md", content: "# Reviewed field notes", noteMeta: nil, expectedRevision: .hash("stale-fixture-revision"))]
            }
            model.messages = [ChatMessage(role: .user, text: "What ideas should I follow up on?"), ChatMessage(role: .assistant, text: answer, sources: sources, fileOps: operations)]
        }
        var requestCount = 0
        model.fixtureResponse = { [self] _ in
            requestCount += 1
            if state == "chat-error" && requestCount == 1 { throw GeminiClientError.requestFailed(statusCode: 503, message: "Synthetic request failure. Try again.") }
            let operations: [VaultFileOperation]
            if state == "stale" {
                let bytes = try Data(contentsOf: root.appendingPathComponent("daily/field-notes.md"))
                operations = [VaultFileOperation(action: .update, path: "daily/field-notes.md", content: "# Reviewed field notes", noteMeta: nil, expectedRevision: .hash(VaultRepository.hash(bytes)))]
            } else { operations = [] }
            return ChatResponse(answer: answer, grounded: true, usedSources: sources, fileOps: operations, warnings: [])
        }
        let index = VaultIndexStore(rootURL: root, persistenceController: controller, userDefaults: defaults)
        model.applyOperations = { [self] operations, id in
            try await VaultApplyService.apply(operations, userDefaults: defaults, rootURL: root, indexStore: index, operationID: id, refreshDerivedPages: {})
        }
        return model
    }
}

#else
// Release has no fixture data or fake provider implementation. The optional seam is always nil.
final class DesignFixture {
    static let current: DesignFixture? = nil
    private init() {}
    var state: String { fatalError("Fixtures require a Debug build") }
    var root: URL { fatalError("Fixtures require a Debug build") }
    var defaults: UserDefaults { fatalError("Fixtures require a Debug build") }
    var controller: PersistenceController { fatalError("Fixtures require a Debug build") }
    static func pageImage() -> Data { fatalError("Fixtures require a Debug build") }
    @MainActor func captureModel() -> CaptureViewModel { fatalError("Fixtures require a Debug build") }
    @MainActor func chatModel() -> ChatViewModel { fatalError("Fixtures require a Debug build") }
}
struct DesignFixtureRoot: View {
    let fixture: DesignFixture
    var body: some View { EmptyView() }
}
enum PresentationDefaults {
    static var current: UserDefaults { .standard }
}
#endif
