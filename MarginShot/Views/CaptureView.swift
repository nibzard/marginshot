import AVFoundation
import CoreData
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import Vision

private func applyVideoRotationAngle(_ angle: CGFloat, to connection: AVCaptureConnection?) {
    guard angle.isFinite else { return }
    guard let connection, connection.isVideoRotationAngleSupported(angle) else { return }
    connection.videoRotationAngle = angle
}

struct CaptureView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.themeColors) private var theme
    @EnvironmentObject private var syncStatus: SyncStatusStore
    @AppStorage("selectedNotebookId") private var selectedNotebookIdRaw = ""
    @Binding var mode: AppMode
    @StateObject private var viewModel = DesignFixture.current?.captureModel() ?? CaptureViewModel()
    @State private var hasBoundContext = false
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \NotebookEntity.createdAt, ascending: true)]
    )
    private var notebooks: FetchedResults<NotebookEntity>
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ScanEntity.createdAt, ascending: false)],
        predicate: NSPredicate(format: "status != %@", ScanStatus.filed.rawValue)
    )
    private var inboxScans: FetchedResults<ScanEntity>
    @State private var isInboxPresented = false
    @State private var isSettingsPresented = false
    @State private var isNotebookPickerPresented = false
    @State private var isBatchPromptPresented = false
    @State private var completedBatchId: UUID?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var importError: String?
    @Binding var importRequested: Bool
    let onAskAboutBatch: (UUID) -> Void

    init(mode: Binding<AppMode> = .constant(.capture), importRequested: Binding<Bool> = .constant(false), onAskAboutBatch: @escaping (UUID) -> Void = { _ in }) {
        _mode = mode
        _importRequested = importRequested
        self.onAskAboutBatch = onAskAboutBatch
    }

    private var selectedNotebookId: UUID? {
        UUID(uuidString: selectedNotebookIdRaw)
    }

    private var resolvedNotebook: NotebookEntity? {
        if let selectedNotebookId,
           let match = notebooks.first(where: { $0.id == selectedNotebookId }) {
            return match
        }
        if let defaultNotebook = notebooks.first(where: { $0.isDefault }) {
            return defaultNotebook
        }
        return notebooks.first
    }

    private var resolvedNotebookName: String {
        resolvedNotebook?.name ?? "Default"
    }

    private var notebookSelectionBinding: Binding<UUID?> {
        Binding(
            get: { UUID(uuidString: selectedNotebookIdRaw) },
            set: { selectedNotebookIdRaw = $0?.uuidString ?? "" }
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if viewModel.sessionState == .ready || viewModel.isProcessing {
                if DesignFixture.current != nil, let image = UIImage(data: DesignFixture.pageImage()) {
                    Image(uiImage: image).resizable().scaledToFit().padding(20)
                } else {
                    CameraPreviewView(controller: viewModel.cameraController)
                        .overlay(DocumentOutlineView(quad: viewModel.detectedQuad, previewLayer: viewModel.cameraController.previewLayer))
                        .ignoresSafeArea(edges: .horizontal)
                }
            } else {
                capturePlaceholder
            }
        }
        .safeAreaInset(edge: .top) {
            if viewModel.sessionState == .ready {
                Text(viewModel.batchNotebookName ?? resolvedNotebookName)
                    .font(.callout).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemBackground))
            }
        }
        .safeAreaInset(edge: .bottom) { captureControls }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isNotebookPickerPresented = true } label: {
                    Label(viewModel.batchNotebookName ?? resolvedNotebookName, systemImage: "book.closed")
                        .lineLimit(2)
                }
                .accessibilityLabel("Choose notebook: \(viewModel.batchNotebookName ?? resolvedNotebookName)")
            }
        }
        .settingsToolbar()
        .photosPicker(isPresented: $importRequested, selection: $photoSelection, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .onAppear {
            if !hasBoundContext {
                viewModel.bind(context: context)
                hasBoundContext = true
            }
            viewModel.ensureDefaultNotebookIfNeeded()
            refreshNotebookSelection()
            if mode == .capture { viewModel.startSessionIfPossible() }
        }
        .onChange(of: scenePhase) { _, phase in
            if mode == .capture { viewModel.handleScenePhase(phase) }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .capture { viewModel.startSessionIfPossible() }
            else { viewModel.cameraController.stopSession(); viewModel.detectedQuad = nil }
        }
        .onChange(of: selectedNotebookIdRaw) { _, _ in viewModel.setSelectedNotebookID(selectedNotebookId) }
        .onChange(of: notebooks.count) { _, _ in refreshNotebookSelection() }
        .sheet(isPresented: $isInboxPresented) { InboxSheet(viewModel: viewModel) }
        .sheet(isPresented: $isNotebookPickerPresented) { NotebookPickerView(selectedNotebookId: notebookSelectionBinding) }
        .confirmationDialog("Pages saved", isPresented: $isBatchPromptPresented, titleVisibility: .visible) {
            Button("Ask about this") {
                guard let batchId = completedBatchId else { return }
                completedBatchId = nil
                onAskAboutBatch(batchId)
            }
            Button("Done", role: .cancel) { completedBatchId = nil }
        } message: {
            Text(PresentationDefaults.current.bool(forKey: "privacySendImagesToLLM") ? "Scans are queued. Processing starts when your setup and background settings allow." : "Pages are saved locally. Allow image processing in Settings when you are ready.")
        }
        .alert("Some photos need attention", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !importing else { return }
        importing = true
        var failures = 0
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CaptureStoreError.unsupportedImage }
                try await viewModel.ingestImage(data)
            } catch { failures += 1 }
        }
        importing = false
        photoSelection = []
        if failures > 0 { importError = "\(failures) photo(s) could not be imported or prepared. Every saved original is retained in pending scans. You can select failed photos again." }
    }

    private func refreshNotebookSelection() {
        guard let resolvedNotebook else { return }
        if selectedNotebookIdRaw != resolvedNotebook.id.uuidString {
            selectedNotebookIdRaw = resolvedNotebook.id.uuidString
        }
        viewModel.setSelectedNotebookID(resolvedNotebook.id)
    }

    private var captureControls: some View {
        VStack(spacing: 12) {
            Text(viewModel.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("captureStatus")
            ViewThatFits(in: .horizontal) {
                CenteredCaptureControlsLayout {
                    importButton
                    shutterButton
                    recentBatch
                }
                VStack(spacing: 12) { shutterButton; importButton; recentBatch }
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(uiColor: .systemBackground))
    }

    private var importButton: some View {
        Button { importRequested = true } label: {
            Label("Import Photos", systemImage: "photo.on.rectangle")
                .font(.callout).fixedSize().frame(minWidth: 44, minHeight: 44)
        }.disabled(viewModel.isProcessing || importing)
    }

    private var shutterButton: some View {
        Button(action: viewModel.captureScan) {
            Circle().strokeBorder(viewModel.canCapture ? theme.accent : Color.secondary, lineWidth: 3)
                .overlay(Circle().fill(viewModel.canCapture ? theme.accent : Color.secondary.opacity(0.3)).padding(7))
                .frame(width: 72, height: 72)
        }
        .accessibilityLabel("Scan a page")
        .disabled(!viewModel.canCapture || importing)
    }

    private var recentBatch: some View {
        VStack(spacing: 4) {
            if viewModel.scanCount > 0 {
                Button("Finish") {
                    if let batchId = viewModel.finishBatch() { completedBatchId = batchId; isBatchPromptPresented = true }
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(theme.scheme == .dark ? .black : .white)
                .disabled(viewModel.isProcessing || importing)
            } else {
                Button { isInboxPresented = true } label: { Image(systemName: "tray").frame(width: 44, height: 44) }
                    .accessibilityLabel("View pending scans")
            }
            Text("\(viewModel.scanCount) pages").font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var capturePlaceholder: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "camera.viewfinder").font(.system(size: 48)).foregroundStyle(.secondary)
                Text(viewModel.permissionTitle).font(.title2.bold())
                Text(viewModel.permissionDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if viewModel.permissionState == .notDetermined && DesignFixture.current == nil {
                    Button("Start scanning") { viewModel.requestPermission() }.buttonStyle(.borderedProminent)
                } else if viewModel.permissionState == .denied {
                    Button("Open Settings") { viewModel.openSettings() }.buttonStyle(.bordered)
                }
                if viewModel.sessionState.canRetry {
                    Button("Try Again") { viewModel.startSessionIfPossible() }.buttonStyle(.bordered)
                }
                Text(viewModel.batchNotebookName ?? resolvedNotebookName)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
    }

}

private struct CenteredCaptureControlsLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let sideWidth = max(sizes[0].width, sizes[2].width)
        let minimumWidth = sizes[1].width + 2 * (sideWidth + spacing)
        return CGSize(
            width: max(proposal.width ?? minimumWidth, minimumWidth),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}

struct InboxSheet: View {
    @State private var processingSettingsPresented = false
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \BatchEntity.createdAt, ascending: false)]
    )
    private var batches: FetchedResults<BatchEntity>

    let viewModel: CaptureViewModel

    var body: some View {
        NavigationStack {
            List {
                if batchSections.isEmpty {
                    Text("No scans waiting")
                        .foregroundColor(.secondary)
                } else {
                    Section {
                        Button("Processing settings") { processingSettingsPresented = true }
                        Text("Original pages are saved locally. Processing follows your image permission, setup, and background settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(batchSections, id: \.batch.objectID) { section in
                        Section {
                            ForEach(section.scans, id: \.objectID) { scan in
                                InboxScanRow(scan: scan) {
                                    viewModel.retryScan(scan)
                                }
                            }
                        } header: {
                            InboxBatchHeader(
                                batch: section.batch,
                                scanCount: section.scans.count
                            ) {
                                viewModel.retryBatch(section.batch)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pending scans")
            .sheet(isPresented: $processingSettingsPresented) { SettingsView(section: .processing) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var batchSections: [(batch: BatchEntity, scans: [ScanEntity])] {
        batches.compactMap { batch in
            let scans = scansForBatch(batch)
            return scans.isEmpty ? nil : (batch: batch, scans: scans)
        }
    }

    private func scansForBatch(_ batch: BatchEntity) -> [ScanEntity] {
        let scans = batch.scans.filter { $0.status != ScanStatus.filed.rawValue }
        return scans.sorted {
            let leftPage = $0.pageNumber?.intValue ?? 0
            let rightPage = $1.pageNumber?.intValue ?? 0
            if leftPage == rightPage {
                return $0.createdAt < $1.createdAt
            }
            return leftPage < rightPage
        }
    }
}

struct InboxBatchHeader: View {
    let batch: BatchEntity
    let scanCount: Int
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = batch.notebook?.name { Text(name).font(.headline).fixedSize(horizontal: false, vertical: true) }
            Text("Batch \(batch.shortID) · \(scanCount) pages").font(.subheadline)
            Text(batch.statusLabel).font(.callout).foregroundStyle(.secondary)
            if batch.statusEnum == .blocked || batch.statusEnum == .error {
                Button("Retry batch", action: onRetry).buttonStyle(.bordered).frame(minHeight: 44)
            }
        }
    }

}

struct InboxScanRow: View {
    let scan: ScanEntity
    let onRetry: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.pageLabel)
                    .font(.subheadline)
                if scan.jobState == ProcessingJobState.paused.rawValue {
                    Label(scan.statusLabel, systemImage: "pause.circle").font(.callout)
                    Text(scan.pauseExplanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if scan.jobState == ProcessingJobState.needsAttention.rawValue || scan.statusEnum == .error {
                    Label(scan.statusLabel, systemImage: "exclamationmark.triangle").font(.callout)
                } else {
                    Text(scan.statusLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if scan.jobState == ProcessingJobState.needsAttention.rawValue || scan.statusEnum == .error {
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = controller.session
        controller.updatePreviewLayer(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== controller.session {
            uiView.videoPreviewLayer.session = controller.session
        }
        controller.updatePreviewLayer(uiView.videoPreviewLayer)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

    struct DocumentOutlineView: View {
        let quad: DocumentQuad?
        let previewLayer: AVCaptureVideoPreviewLayer?

        var body: some View {
            GeometryReader { _ in
                if let quad,
                   quad.isNormalizedFinite,
                   let previewLayer,
                   previewLayer.bounds.width.isFinite,
                   previewLayer.bounds.height.isFinite,
                   previewLayer.bounds.width > 0,
                   previewLayer.bounds.height > 0 {
                    let converted = quad.converted(using: previewLayer)
                    if converted.isFinite {
                        Path { path in
                            path.move(to: converted.topLeft)
                            path.addLine(to: converted.topRight)
                            path.addLine(to: converted.bottomRight)
                            path.addLine(to: converted.bottomLeft)
                            path.closeSubpath()
                        }
                        .stroke(Color.green.opacity(0.85), lineWidth: 2)
                        .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

struct DocumentQuad: Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    var isFinite: Bool {
        [topLeft, topRight, bottomRight, bottomLeft].allSatisfy { point in
            point.x.isFinite && point.y.isFinite
        }
    }

    var isNormalizedFinite: Bool {
        [topLeft, topRight, bottomRight, bottomLeft].allSatisfy { point in
            point.x.isFinite && point.y.isFinite &&
                (0...1).contains(point.x) &&
                (0...1).contains(point.y)
        }
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    init(observation: VNRectangleObservation) {
        topLeft = observation.topLeft
        topRight = observation.topRight
        bottomRight = observation.bottomRight
        bottomLeft = observation.bottomLeft
    }

    func converted(using layer: AVCaptureVideoPreviewLayer) -> DocumentQuad {
        func convert(_ point: CGPoint) -> CGPoint {
            let devicePoint = CGPoint(x: point.x, y: 1 - point.y)
            let converted = layer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
            // If conversion produces NaN, return origin to avoid CoreGraphics errors
            guard converted.x.isFinite, converted.y.isFinite else {
                return .zero
            }
            return converted
        }

        return DocumentQuad(
            topLeft: convert(topLeft),
            topRight: convert(topRight),
            bottomRight: convert(bottomRight),
            bottomLeft: convert(bottomLeft)
        )
    }
}

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var statusText: String = "Choose a page to begin"
    @Published var sessionState: CameraSessionState = .idle
    @Published var batchNotebookName: String?
    private var batchNotebookID: UUID?
    @Published var scanCount: Int = 0
    @Published var isProcessing: Bool = false
    @Published var permissionState: CameraPermissionState = .notDetermined
    @Published var detectedQuad: DocumentQuad?
    @Published var selectedNotebookID: UUID?

    let cameraController: CameraController

    private var context: NSManagedObjectContext?
    private var batchId = UUID().uuidString
    private var pageIndex = 0
    private var captureRequestedAt: TimeInterval?
    private let captureStore: CaptureStore

    var canCapture: Bool { permissionState == .authorized && sessionState == .ready && !isProcessing }

    var permissionTitle: String {
        if (DesignFixture.current != nil && DesignFixture.current?.state != "camera-denied" && sessionState != .ready) || sessionState == .unavailable { return "Camera unavailable" }
        switch permissionState {
        case .authorized: return sessionState == .ready ? "Ready to scan" : sessionState.title
        case .denied: return "Camera access is off"
        case .restricted: return "Camera access is restricted"
        case .notDetermined: return "Your next idea starts here"
        }
    }

    var permissionDetail: String {
        if sessionState == .unavailable || (DesignFixture.current != nil && DesignFixture.current?.state != "camera-denied" && sessionState != .ready) { return "Import photos to add notebook pages on this device." }
        switch permissionState {
        case .authorized: return sessionState.detail
        case .denied: return "Allow camera access in Settings, or import selected photos. Library and Chat are always available."
        case .restricted: return "You can still import selected photos and browse your notes."
        case .notDetermined: return "Scan a notebook page or import photos. Originals are saved on your device."
        }
    }

    private let enqueueProcessing: () -> Void

    init(captureStore: CaptureStore = CaptureStore(), enqueueProcessing: @escaping () -> Void = { ProcessingQueue.shared.enqueuePendingProcessing() }) {
        self.captureStore = captureStore
        self.enqueueProcessing = enqueueProcessing
        let controller = CameraController()
        cameraController = controller
        controller.onDetectedQuad = { [weak self] quad in
            guard let self, self.cameraController.session.isRunning else { return }
            Task { @MainActor in
                self.detectedQuad = quad
            }
        }
        controller.onPhotoCapture = { [weak self] result in
            Task { @MainActor in
                self?.handlePhotoCapture(result)
            }
        }
        controller.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.sessionState = state
                if self?.isProcessing == false { self?.statusText = state.title }
            }
        }
        controller.onSessionError = { [weak self] error in
            Task { @MainActor in
                self?.statusText = "Camera error: \(error.localizedDescription)"
            }
        }
    }

    func bind(context: NSManagedObjectContext) {
        self.context = context
        refreshPermission()
    }

    func setSelectedNotebookID(_ id: UUID?) {
        selectedNotebookID = id
    }

    func ensureDefaultNotebookIfNeeded() {
        guard let context else { return }
        let request = NotebookEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "isDefault == YES")
        if let _ = try? context.fetch(request).first {
            return
        }

        let fallbackRequest = NotebookEntity.fetchRequest()
        fallbackRequest.fetchLimit = 1
        if let existing = try? context.fetch(fallbackRequest).first {
            existing.isDefault = true
            existing.updatedAt = Date()
            try? context.save()
            return
        }

        let notebook = NotebookEntity(context: context)
        notebook.id = UUID()
        notebook.name = "Default"
        notebook.isDefault = true
        notebook.createdAt = Date()
        notebook.updatedAt = Date()
        try? context.save()
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.permissionState = granted ? .authorized : .denied
                if granted {
                    self?.startSessionIfPossible()
                }
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func startSessionIfPossible() {
        if let fixture = DesignFixture.current {
            if ["camera-ready", "batch", "saving"].contains(fixture.state) {
                permissionState = .authorized
                sessionState = .ready
                statusText = isProcessing ? "Saving page…" : "Ready to scan"
            } else if fixture.state == "camera-denied" {
                permissionState = .denied
                sessionState = .idle
                statusText = "Camera access is off"
            } else { sessionState = .unavailable; statusText = "Camera unavailable" }
            return
        }
        refreshPermission()
        guard permissionState == .authorized else { return }
        cameraController.configureSessionIfNeeded()
        cameraController.startSession()

    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startSessionIfPossible()
        case .inactive, .background:
            cameraController.stopSession()
            detectedQuad = nil
        @unknown default:
            break
        }
    }

    func captureScan() {
        guard canCapture else { return }
        isProcessing = true
        statusText = "Capturing..."
        captureRequestedAt = CFAbsoluteTimeGetCurrent()
        if DesignFixture.current != nil {
            Task { try? await ingestImage(DesignFixture.pageImage(), alreadySaving: true) }
        } else { cameraController.capturePhoto() }
    }

    private func refreshPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permissionState = .authorized
        case .denied:
            permissionState = .denied
        case .restricted:
            permissionState = .restricted
        case .notDetermined:
            permissionState = .notDetermined
        @unknown default:
            permissionState = .restricted
        }
        if !isProcessing {
            statusText = permissionTitle
        }
    }

    private func handlePhotoCapture(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            if let captureRequestedAt {
                let shutterLatency = CFAbsoluteTimeGetCurrent() - captureRequestedAt
                self.captureRequestedAt = nil
                Task { @MainActor in
                    PerformanceMetricsStore.shared.recordDuration(.captureShutterLatency, seconds: shutterLatency)
                }
            }
            Task { [weak self] in
                do { try await self?.ingestImage(data, alreadySaving: true) }
                catch { self?.statusText = "Page needs attention. Check pending scans." }
            }
        case .failure(let error):
            statusText = "Capture failed: \(error.localizedDescription)"
            isProcessing = false
            captureRequestedAt = nil
        }
    }

    func ingestImage(_ data: Data, alreadySaving: Bool = false) async throws {
        guard alreadySaving || !isProcessing else { throw CaptureStoreError.metadataUnavailable }
        isProcessing = true
        defer { isProcessing = false }
        statusText = "Saving page…"
        let format: CaptureImageFormat
        do { format = try await Task.detached { try CaptureImageFormat.validated(data) }.value }
        catch {
            if alreadySaving {
                // A camera result must be journaled even if decoding fails. Preserve legacy JPEG fallback.
                format = .jpeg
            } else {
                statusText = "Unsupported photo. Select a JPEG, PNG, or HEIC image."
                throw error
            }
        }
        let nextIndex = pageIndex + 1
        let currentBatchID = UUID(uuidString: batchId)!
        if pageIndex == 0 { batchNotebookID = selectedNotebookID }
        let notebookID = batchNotebookID
        let store = captureStore
        var rawPath: String?
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                try store.placeOriginal(data, batchID: currentBatchID, notebookID: notebookID, pageNumber: nextIndex, format: format)
            }.value
            guard let context else { throw CaptureStoreError.metadataUnavailable }
            try store.persist(record, in: context)
            rawPath = record.rawPath
            pageIndex = nextIndex
            scanCount = nextIndex
            let request = NotebookEntity.fetchRequest()
            if let notebookID { request.predicate = NSPredicate(format: "id == %@", notebookID as CVarArg) }
            batchNotebookName = try context.fetch(request).first?.name
            let processedPath = try await Task.detached(priority: .userInitiated) {
                let processed = try DocumentProcessingPipeline.process(imageData: data)
                return try VaultScanStore.saveProcessedScan(processedData: processed.processedData, rawPath: record.rawPath, rootURL: store.rootURL, userDefaults: store.userDefaults)
            }.value
            guard updateScanStatus(forRawPath: record.rawPath, status: .captured, processedPath: processedPath) else { throw CaptureStoreError.metadataUnavailable }
            statusText = "Saved page \(nextIndex)"
        } catch {
            if let rawPath { updateScanStatus(forRawPath: rawPath, status: .error, processedPath: nil) }
            statusText = rawPath == nil ? "Could not save page. Try importing again." : "Original saved. Preparation needs attention in pending scans."
            throw error
        }
    }

    @discardableResult
    private func updateScanStatus(forRawPath rawPath: String, status: ScanStatus, processedPath: String?) -> Bool {
        guard let context else { return false }
        let request = ScanEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "imagePath == %@", rawPath)
        do {
            guard let scan = try context.fetch(request).first else { return false }
            scan.status = status.rawValue
            if let processedPath {
                scan.processedImagePath = processedPath
            } else if status == .error {
                scan.processedImagePath = nil
            }
            scan.jobState = (status == .error ? ProcessingJobState.needsAttention : ProcessingJobState.pending).rawValue
            scan.jobCheckpoint = processedPath == nil ? "original" : "inputReady"
            try context.save()
            return true
        } catch {
            statusText = "Scan update failed"
            return false
        }
    }

    @discardableResult
    func finishBatch() -> UUID? {
        guard !isProcessing, scanCount > 0, let context, let batchUUID = UUID(uuidString: batchId) else { return nil }
        do {
            let finishedBatchId = try captureStore.finishBatch(batchUUID, in: context)
            statusText = "Batch queued"
            enqueueProcessing()
            resetBatchSession()
            return finishedBatchId
        } catch {
            statusText = "Batch update failed"
            return nil
        }
    }

    func retryScan(_ scan: ScanEntity) {
        guard !isProcessing else { return }
        guard let context else { return }

        if scan.processedImagePath != nil {
            requeueProcessing(for: scan, context: context)
            return
        }

        let rawPath = scan.imagePath
        scan.status = ScanStatus.preprocessing.rawValue
        statusText = "Retrying scan..."
        isProcessing = true

        do {
            try context.save()
        } catch {
            statusText = "Retry failed"
            isProcessing = false
            return
        }

        let store = captureStore
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanPath = rawPath
            do {
                let rawURL = store.rootURL.appendingPathComponent(scanPath)
                let rawData = try VaultFileStore.readData(from: rawURL, userDefaults: store.userDefaults)
                let processed = try DocumentProcessingPipeline.process(imageData: rawData)
                let processedPath = try VaultScanStore.saveProcessedScan(
                    processedData: processed.processedData,
                    rawPath: scanPath, rootURL: store.rootURL, userDefaults: store.userDefaults
                )
                await MainActor.run { [weak self] in
                    self?.updateScanStatus(
                        forRawPath: scanPath,
                        status: .captured,
                        processedPath: processedPath
                    )
                    self?.queueBatchProcessing(forRawPath: scanPath)
                    self?.statusText = "Retry complete"
                    self?.isProcessing = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.updateScanStatus(forRawPath: scanPath, status: .error, processedPath: nil)
                    self?.statusText = "Retry failed"
                    self?.isProcessing = false
                }
            }
        }
    }

    func retryBatch(_ batch: BatchEntity) {
        guard let context else { return }
        let pendingScans = batch.scans.filter { ScanStatus(rawValue: $0.status) != .filed }
        guard !pendingScans.isEmpty else { return }

        var scansNeedingPreprocess: [String] = []
        for scan in pendingScans {
            scan.jobState = ProcessingJobState.pending.rawValue
            scan.jobNextRetryAt = nil
            scan.jobFailure = nil
            guard let status = ScanStatus(rawValue: scan.status) else { continue }
            if status == .error || status == .preprocessing {
                if scan.processedImagePath == nil {
                    scan.status = ScanStatus.preprocessing.rawValue
                    scansNeedingPreprocess.append(scan.imagePath)
                } else {
                    scan.status = ScanStatus.captured.rawValue
                }
            }
        }
        batch.status = BatchStatus.queued.rawValue
        batch.updatedAt = Date()

        do {
            try context.save()
            if scansNeedingPreprocess.isEmpty {
                statusText = "Batch queued"
                enqueueProcessing()
                return
            }
        } catch {
            statusText = "Retry failed"
            return
        }

        statusText = "Retrying batch..."
        isProcessing = true

        let store = captureStore
        Task.detached(priority: .userInitiated) { [weak self] in
            let scansToProcess = scansNeedingPreprocess
            for rawPath in scansToProcess {
                do {
                    let rawURL = store.rootURL.appendingPathComponent(rawPath)
                    let rawData = try VaultFileStore.readData(from: rawURL, userDefaults: store.userDefaults)
                    let processed = try DocumentProcessingPipeline.process(imageData: rawData)
                    let processedPath = try VaultScanStore.saveProcessedScan(
                        processedData: processed.processedData,
                        rawPath: rawPath, rootURL: store.rootURL, userDefaults: store.userDefaults
                    )
                    await MainActor.run { [weak self] in
                        _ = self?.updateScanStatus(
                            forRawPath: rawPath,
                            status: .captured,
                            processedPath: processedPath
                        )
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        _ = self?.updateScanStatus(forRawPath: rawPath, status: .error, processedPath: nil)
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.statusText = "Batch queued"
                self?.isProcessing = false
                self?.enqueueProcessing()
            }
        }
    }

    private func requeueProcessing(for scan: ScanEntity, context: NSManagedObjectContext) {
        scan.status = scan.jobCheckpoint == "structured" ? ScanStatus.structured.rawValue : ScanStatus.captured.rawValue
        scan.jobState = ProcessingJobState.pending.rawValue
        scan.jobFailure = nil
        scan.jobNextRetryAt = nil
        if let batch = scan.batch {
            batch.status = BatchStatus.queued.rawValue
            batch.updatedAt = Date()
        }

        do {
            try context.save()
            statusText = "Queued for processing"
            enqueueProcessing()
        } catch {
            statusText = "Retry failed"
        }
    }

    private func queueBatchProcessing(forRawPath rawPath: String) {
        guard let context else { return }
        let request = ScanEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "imagePath == %@", rawPath)
        guard let scan = try? context.fetch(request).first else { return }
        if let batch = scan.batch {
            batch.status = BatchStatus.queued.rawValue
            batch.updatedAt = Date()
        }
        try? context.save()
        enqueueProcessing()
    }

    private func resetBatchSession() {
        batchId = UUID().uuidString
        pageIndex = 0
        scanCount = 0
        batchNotebookID = nil
        batchNotebookName = nil
    }


}

enum CameraPermissionState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

final class CameraController: NSObject {
    let session = AVCaptureSession()
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    var onDetectedQuad: ((DocumentQuad?) -> Void)?
    var onPhotoCapture: ((Result<Data, Error>) -> Void)?
    var onSessionError: ((Error) -> Void)?
    var onStateChange: ((CameraSessionState) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private let sessionQueue = DispatchQueue(label: "marginshot.camera.session")
    private let videoQueue = DispatchQueue(label: "marginshot.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var cameraDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var isConfigured = false
    private var wantsRunning = false
    private var isDetecting = false
    private var lastDetectionTime: CFTimeInterval = 0

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification, AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStartRunningNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                guard let self else { return }
                self.sessionQueue.async {
                    if notification.name == AVCaptureSession.runtimeErrorNotification {
                        self.onStateChange?(self.wantsRunning ? .failed : .idle)
                    } else if notification.name == AVCaptureSession.wasInterruptedNotification {
                        self.onStateChange?(self.wantsRunning ? .interrupted : .idle)
                    } else { self.publishReadiness() }
                }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func publishReadiness() {
        if !wantsRunning { onStateChange?(.idle) }
        else if session.isInterrupted { onStateChange?(.interrupted) }
        else if isConfigured && session.isRunning,
                let connection = photoOutput.connection(with: .video), connection.isEnabled && connection.isActive { onStateChange?(.ready) }
        else { onStateChange?(.failed) }
    }

    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }
            self.onStateChange?(.configuring)
            do {
                try self.configureSession()
                self.isConfigured = true
            } catch {
                self.onStateChange?((error as? CameraControllerError) == .cameraUnavailable ? .unavailable : .failed)
                self.onSessionError?(error)
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            guard self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.publishReadiness()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.onStateChange?(.idle)
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else {
                self.onPhotoCapture?(.failure(CameraControllerError.sessionNotConfigured))
                return
            }
            guard self.session.isRunning else {
                self.onPhotoCapture?(.failure(CameraControllerError.sessionNotRunning))
                return
            }
            guard let connection = self.photoOutput.connection(with: .video),
                  connection.isEnabled,
                  connection.isActive else {
                self.onPhotoCapture?(.failure(CameraControllerError.captureConnectionUnavailable))
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .balanced
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func updatePreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        DispatchQueue.main.async { [weak self] in
            self?.previewLayer = layer
            self?.updateRotationCoordinator(previewLayer: layer)
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraControllerError.cameraUnavailable
        }
        cameraDevice = camera

        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) {
            session.addInput(input)
        } else { throw CameraControllerError.sessionNotConfigured }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        } else { throw CameraControllerError.sessionNotConfigured }
        if let maxDimensions = maxPhotoDimensions(for: camera) {
            photoOutput.maxPhotoDimensions = maxDimensions
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        DispatchQueue.main.async { [weak self] in
            self?.updateRotationCoordinator()
        }
    }

    private func maxPhotoDimensions(for camera: AVCaptureDevice) -> CMVideoDimensions? {
        let supportedDimensions = camera.activeFormat.supportedMaxPhotoDimensions
        return supportedDimensions.max { lhs, rhs in
            let lhsArea = Int64(lhs.width) * Int64(lhs.height)
            let rhsArea = Int64(rhs.width) * Int64(rhs.height)
            return lhsArea < rhsArea
        }
    }

    private func updateRotationCoordinator(previewLayer: AVCaptureVideoPreviewLayer? = nil) {
        guard let cameraDevice else { return }
        let layer = previewLayer ?? self.previewLayer
        guard let layer,
              layer.bounds.width.isFinite,
              layer.bounds.height.isFinite,
              layer.bounds.width > 0,
              layer.bounds.height > 0 else {
            return
        }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: cameraDevice, previewLayer: layer)
        applyRotationAngles()
    }

    private func applyRotationAngles() {
        guard let rotationCoordinator else { return }
        applyVideoRotationAngle(
            rotationCoordinator.videoRotationAngleForHorizonLevelPreview,
            to: previewLayer?.connection
        )
        let captureAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
        applyVideoRotationAngle(captureAngle, to: videoOutput.connection(with: .video))
        applyVideoRotationAngle(captureAngle, to: photoOutput.connection(with: .video))
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            onPhotoCapture?(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            onPhotoCapture?(.failure(CameraControllerError.captureFailed))
            return
        }
        onPhotoCapture?(.success(data))
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard connection.isEnabled, connection.isActive else { return }
        let now = CACurrentMediaTime()
        guard now - lastDetectionTime > 0.2 else { return }
        guard !isDetecting else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isDetecting = true
        lastDetectionTime = now

        let request = VNDetectRectanglesRequest { [weak self] request, _ in
            let observation = request.results?.first as? VNRectangleObservation
            self?.isDetecting = false
            DispatchQueue.main.async {
                self?.onDetectedQuad?(observation.map(DocumentQuad.init))
            }
        }
        request.maximumObservations = 1
        request.minimumSize = 0.2
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.5

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )
        try? handler.perform([request])
    }
}

enum CameraControllerError: LocalizedError, Equatable {
    case cameraUnavailable
    case captureFailed
    case sessionNotConfigured
    case sessionNotRunning
    case captureConnectionUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Camera unavailable"
        case .captureFailed:
            return "Capture failed"
        case .sessionNotConfigured:
            return "Camera session not configured"
        case .sessionNotRunning:
            return "Camera session not running"
        case .captureConnectionUnavailable:
            return "Camera connection unavailable"
        }
    }
}

struct ProcessedScan {
    let rawData: Data
    let processedData: Data
}

enum DocumentProcessingError: Error {
    case invalidImage
    case renderFailed
}

enum DocumentProcessingPipeline {
    static let context = CIContext()

    static func process(imageData: Data) throws -> ProcessedScan {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw DocumentProcessingError.invalidImage
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let baseImage = CIImage(cgImage: cgImage).oriented(orientation)
        let observation = DocumentDetector.detect(in: cgImage, orientation: orientation)

        let corrected = observation.map { applyPerspectiveCorrection(to: baseImage, with: $0) } ?? baseImage
        let enhanced = applyEnhancements(to: corrected)

        guard let output = context.createCGImage(enhanced, from: enhanced.extent),
              let processedData = UIImage(cgImage: output).jpegData(compressionQuality: 0.85) else {
            throw DocumentProcessingError.renderFailed
        }

        return ProcessedScan(rawData: imageData, processedData: processedData)
    }

    private static func applyPerspectiveCorrection(
        to image: CIImage,
        with observation: VNRectangleObservation
    ) -> CIImage {
        let size = image.extent.size
        let topLeft = CGPoint(x: observation.topLeft.x * size.width, y: observation.topLeft.y * size.height)
        let topRight = CGPoint(x: observation.topRight.x * size.width, y: observation.topRight.y * size.height)
        let bottomLeft = CGPoint(x: observation.bottomLeft.x * size.width, y: observation.bottomLeft.y * size.height)
        let bottomRight = CGPoint(x: observation.bottomRight.x * size.width, y: observation.bottomRight.y * size.height)

        let corrected = image.applyingFilter(
            "CIPerspectiveCorrection",
            parameters: [
                "inputTopLeft": CIVector(cgPoint: topLeft),
                "inputTopRight": CIVector(cgPoint: topRight),
                "inputBottomLeft": CIVector(cgPoint: bottomLeft),
                "inputBottomRight": CIVector(cgPoint: bottomRight)
            ]
        )
        return corrected
    }

    private static func applyEnhancements(to image: CIImage) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.contrast = 1.2
        controls.brightness = 0.02
        controls.saturation = 1.0

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controls.outputImage
        sharpen.sharpness = 0.4

        return sharpen.outputImage ?? image
    }
}

enum DocumentDetector {
    static func detect(in cgImage: CGImage, orientation: CGImagePropertyOrientation) -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumSize = 0.2
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.5

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNRectangleObservation
    }
}

struct StoredScan: Sendable {
    let rawPath: String
    let processedPath: String?
}

enum VaultScanStore {
    static func saveProcessedScan(processedData: Data, rawPath: String, rootURL: URL? = nil, userDefaults: UserDefaults = .standard) throws -> String {
        let processedPath = processedPath(from: rawPath)
        let processedURL = try rootURL?.appendingPathComponent(processedPath) ?? url(for: processedPath)
        try VaultFileStore.writeData(processedData, to: processedURL, userDefaults: userDefaults)
        return processedPath
    }

    static func metadataPath(for imagePath: String) -> String {
        let nsPath = imagePath as NSString
        let directory = nsPath.deletingLastPathComponent
        let baseName = nsPath.deletingPathExtension
        let fileBase = (baseName as NSString).lastPathComponent
        let trimmedBase: String
        if fileBase.hasSuffix("-raw") {
            trimmedBase = String(fileBase.dropLast(4))
        } else {
            trimmedBase = fileBase
        }
        let fileName = "\(trimmedBase).json"
        if directory.isEmpty {
            return fileName
        }
        return (directory as NSString).appendingPathComponent(fileName)
    }

    static func url(for relativePath: String) throws -> URL {
        try vaultRootURL().appendingPathComponent(relativePath)
    }

    private static func processedPath(from rawPath: String) -> String {
        let rawNSString = rawPath as NSString
        let basePath = rawNSString.deletingPathExtension
        let ext = rawNSString.pathExtension
        let trimmedBase: String
        if basePath.hasSuffix("-raw") {
            trimmedBase = String(basePath.dropLast(4))
        } else {
            trimmedBase = basePath + "-processed"
        }

        if ext.isEmpty {
            return trimmedBase
        }
        return "\(trimmedBase).jpg"
    }

    private static func vaultRootURL() throws -> URL {
        if let fixture = DesignFixture.current { return fixture.root }
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultStorageError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }
}

enum VaultStorageError: Error {
    case documentsDirectoryUnavailable
}

extension ScanStatus {
    var label: String {
        switch self {
        case .captured:
            return "Captured"
        case .preprocessing:
            return "Preprocessing"
        case .transcribing:
            return "Transcribing"
        case .structured:
            return "Structured"
        case .filed:
            return "Filed"
        case .error:
            return "Needs attention"
        }
    }
}

extension BatchStatus {
    var label: String {
        switch self {
        case .open:
            return "Open"
        case .queued:
            return "Queued"
        case .processing:
            return "Processing"
        case .done:
            return "Done"
        case .blocked:
            return "Needs attention"
        case .error:
            return "Needs attention"
        }
    }
}

extension ScanEntity {
    var statusEnum: ScanStatus? {
        ScanStatus(rawValue: status)
    }

    var statusLabel: String {
        switch ProcessingJobState(rawValue: jobState ?? "") {
        case .paused: return "Paused"
        case .retryScheduled: return "Paused — will retry"
        case .needsAttention: return "Needs attention"
        case .running: return "Processing"
        case .complete: return "Saved to vault"
        default: return statusEnum == .preprocessing ? "Preparing scan" : (statusEnum == .captured ? "Saved" : (statusEnum?.label ?? status.capitalized))
        }
    }

    var pauseExplanation: String {
        switch jobFailure {
        case "privacy", "imageUploadsDisabled": return "Image processing is off. You can change this in Processing settings."
        case "charging": return "Waiting for this device to charge."
        case "network": return "Waiting for a connection allowed by your Processing settings."
        case "cancelledOrPrivacy": return "Processing stopped. Check image permission and background settings before retrying."
        default: return "Check Processing settings to continue. Your original is retained."
        }
    }

    var pageLabel: String {
        guard let pageNumber = pageNumber?.intValue, pageNumber > 0 else {
            return "Page"
        }
        return "Page \(pageNumber)"
    }
}

extension BatchEntity {
    var statusEnum: BatchStatus? {
        BatchStatus(rawValue: status)
    }

    var statusLabel: String {
        statusEnum?.label ?? status.capitalized
    }

    var shortID: String {
        String(id.uuidString.prefix(6))
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .down:
            self = .down
        case .left:
            self = .left
        case .right:
            self = .right
        case .upMirrored:
            self = .upMirrored
        case .downMirrored:
            self = .downMirrored
        case .leftMirrored:
            self = .leftMirrored
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}

#Preview {
    CaptureView(mode: .constant(.capture))
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(SyncStatusStore.shared)
}
