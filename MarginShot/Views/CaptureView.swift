import AVFoundation
import CoreData
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UIKit
import Vision

struct CaptureView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CaptureViewModel()
    @State private var hasBoundContext = false
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ScanEntity.createdAt, ascending: false)],
        predicate: NSPredicate(format: "status != %@", ScanStatus.filed.rawValue)
    )
    private var inboxScans: FetchedResults<ScanEntity>
    @State private var isInboxPresented = false
    @State private var isBatchPromptPresented = false
    @State private var completedBatchId: UUID?
    let onAskAboutBatch: (UUID) -> Void

    init(onAskAboutBatch: @escaping (UUID) -> Void = { _ in }) {
        self.onAskAboutBatch = onAskAboutBatch
    }

    var body: some View {
        ZStack {
            if viewModel.permissionState == .authorized {
                CameraPreviewView(controller: viewModel.cameraController)
                    .overlay(
                        DocumentOutlineView(
                            quad: viewModel.detectedQuad,
                            previewLayer: viewModel.cameraController.previewLayer
                        )
                    )
                    .ignoresSafeArea()
            } else {
                capturePlaceholder
            }

            VStack {
                topBar
                Spacer()
                captureControls
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            if viewModel.isProcessing {
                ProcessingOverlay()
            }
        }
        .onAppear {
            if !hasBoundContext {
                viewModel.bind(context: context)
                hasBoundContext = true
            }
            viewModel.startSessionIfPossible()
        }
        .onChange(of: scenePhase) { phase in
            viewModel.handleScenePhase(phase)
        }
        .sheet(isPresented: $isInboxPresented) {
            InboxSheet(viewModel: viewModel)
        }
        .confirmationDialog("Batch queued", isPresented: $isBatchPromptPresented, titleVisibility: .visible) {
            Button("Ask about this") {
                guard let batchId = completedBatchId else { return }
                completedBatchId = nil
                onAskAboutBatch(batchId)
            }
            Button("Not now", role: .cancel) {
                completedBatchId = nil
            }
        } message: {
            Text("Processing in background. Ask about this batch while we finish organizing.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            statusPill
            Spacer()
            inboxButton
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.statusTint)
                .frame(width: 8, height: 8)
            Text(viewModel.statusText)
                .font(.footnote)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var inboxButton: some View {
        Button {
            isInboxPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                Text("Inbox: \(inboxScans.count)")
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Inbox \(inboxScans.count)")
    }

    private var captureControls: some View {
        VStack(spacing: 16) {
            Button(action: viewModel.captureScan) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 4)
                    Circle()
                        .fill(viewModel.canCapture ? Color.white : Color.gray.opacity(0.6))
                        .padding(6)
                }
                .frame(width: 72, height: 72)
            }
            .disabled(!viewModel.canCapture)

            HStack(spacing: 12) {
                Text("Batch: On")
                Text("Scans: \(viewModel.scanCount)")
                if viewModel.scanCount > 0 {
                    Button("Finish") {
                        if let batchId = viewModel.finishBatch() {
                            completedBatchId = batchId
                            isBatchPromptPresented = true
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.2), in: Capsule())
                    .disabled(viewModel.isProcessing)
                }
            }
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.45), in: Capsule())
        }
    }

    private var capturePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray5), Color(.systemGray4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 36, weight: .semibold))
                Text(viewModel.permissionTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(viewModel.permissionDetail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if viewModel.permissionState == .notDetermined {
                    Button("Allow Camera") {
                        viewModel.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                } else if viewModel.permissionState == .denied {
                    Button("Open Settings") {
                        viewModel.openSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
        }
    }
}

struct ProcessingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            ProgressView("Processing scan...")
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct InboxSheet: View {
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
                    Text("Inbox is clear.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(batchSections, id: \.batch.objectID) { section in
                        Section {
                            ForEach(section.scans, id: \.objectID) { scan in
                                InboxScanRow(scan: scan) {
                                    viewModel.retryScan(scan)
                                }
                            }
                        } header: {
                            InboxBatchHeader(batch: section.batch, scanCount: section.scans.count)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Inbox")
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

    var body: some View {
        HStack(spacing: 8) {
            Text("Batch \(batch.shortID)")
                .font(.subheadline)
            Spacer()
            Text(batch.statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("\(scanCount) scans")
                .font(.caption)
                .foregroundColor(.secondary)
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
                Text(scan.statusLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if scan.statusEnum == .error {
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
        controller.previewLayer = view.videoPreviewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== controller.session {
            uiView.videoPreviewLayer.session = controller.session
        }
        if let connection = uiView.videoPreviewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        controller.previewLayer = uiView.videoPreviewLayer
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
            if let quad, let previewLayer {
                let converted = quad.converted(using: previewLayer)
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
        .allowsHitTesting(false)
    }
}

struct DocumentQuad: Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    init(observation: VNRectangleObservation) {
        topLeft = observation.topLeft
        topRight = observation.topRight
        bottomRight = observation.bottomRight
        bottomLeft = observation.bottomLeft
    }

    func converted(using layer: AVCaptureVideoPreviewLayer) -> DocumentQuad {
        func convert(_ point: CGPoint) -> CGPoint {
            let devicePoint = CGPoint(x: point.x, y: 1 - point.y)
            return layer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
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
    @Published var statusText: String = "Scanner Ready"
    @Published var scanCount: Int = 0
    @Published var isProcessing: Bool = false
    @Published var permissionState: CameraPermissionState = .notDetermined
    @Published var detectedQuad: DocumentQuad?

    let cameraController: CameraController

    private var context: NSManagedObjectContext?
    private var batchId = UUID().uuidString
    private var pageIndex = 0
    private var currentBatchObjectID: NSManagedObjectID?

    var statusTint: Color {
        if isProcessing {
            return .yellow
        }
        switch permissionState {
        case .authorized:
            return .green
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .orange
        }
    }

    var canCapture: Bool {
        permissionState == .authorized && !isProcessing
    }

    var permissionTitle: String {
        switch permissionState {
        case .authorized:
            return "Scanner Ready"
        case .denied:
            return "Camera Access Needed"
        case .restricted:
            return "Camera Restricted"
        case .notDetermined:
            return "Allow Camera Access"
        }
    }

    var permissionDetail: String {
        switch permissionState {
        case .authorized:
            return "Point at a page to detect the document frame."
        case .denied:
            return "Enable camera access in Settings to scan pages."
        case .restricted:
            return "Camera access is restricted on this device."
        case .notDetermined:
            return "MarginShot needs the camera to scan notebooks."
        }
    }

    init() {
        let controller = CameraController()
        cameraController = controller
        controller.onDetectedQuad = { [weak self] quad in
            Task { @MainActor in
                self?.detectedQuad = quad
            }
        }
        controller.onPhotoCapture = { [weak self] result in
            Task { @MainActor in
                self?.handlePhotoCapture(result)
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
        refreshPermission()
        guard permissionState == .authorized else { return }
        cameraController.configureSessionIfNeeded()
        cameraController.startSession()
        statusText = isProcessing ? "Processing scan..." : "Scanner Ready"
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
        cameraController.capturePhoto()
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
            statusText = permissionState == .authorized ? "Scanner Ready" : permissionTitle
        }
    }

    private func handlePhotoCapture(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            statusText = "Processing scan..."
            let nextIndex = pageIndex + 1
            let batchId = batchId
            Task.detached(priority: .userInitiated) { [weak self] in
                var rawPath: String?
                do {
                    let stored = try VaultScanStore.saveScan(
                        rawData: data,
                        processedData: nil,
                        batchId: batchId,
                        pageIndex: nextIndex
                    )
                    rawPath = stored.rawPath
                    await MainActor.run {
                        guard let self else { return }
                        self.pageIndex = nextIndex
                        self.scanCount = nextIndex
                        self.persistScanIfPossible(stored, pageIndex: nextIndex, status: .preprocessing)
                    }

                    let processed = try DocumentProcessingPipeline.process(imageData: data)
                    let processedPath = try VaultScanStore.saveProcessedScan(
                        processedData: processed.processedData,
                        rawPath: stored.rawPath
                    )

                    await MainActor.run {
                        guard let self else { return }
                        self.updateScanStatus(
                            forRawPath: stored.rawPath,
                            status: .captured,
                            processedPath: processedPath
                        )
                        self.statusText = "Saved scan \(nextIndex)"
                        self.isProcessing = false
                    }
                } catch {
                    await MainActor.run {
                        if let rawPath {
                            self?.updateScanStatus(forRawPath: rawPath, status: .error, processedPath: nil)
                        }
                        self?.statusText = "Processing failed"
                        self?.isProcessing = false
                    }
                }
            }
        case .failure:
            statusText = "Capture failed"
            isProcessing = false
        }
    }

    private func persistScanIfPossible(_ stored: StoredScan, pageIndex: Int, status: ScanStatus) {
        guard let context else { return }
        do {
            let batch = try fetchOrCreateBatch(in: context)
            let scan = ScanEntity(context: context)
            scan.id = UUID()
            scan.createdAt = Date()
            scan.status = status.rawValue
            scan.imagePath = stored.rawPath
            scan.processedImagePath = stored.processedPath
            scan.pageNumber = NSNumber(value: pageIndex)
            scan.batch = batch
            try context.save()
        } catch {
            statusText = "Saved scan, metadata failed"
        }
    }

    private func updateScanStatus(forRawPath rawPath: String, status: ScanStatus, processedPath: String?) {
        guard let context else { return }
        let request = ScanEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "imagePath == %@", rawPath)
        do {
            guard let scan = try context.fetch(request).first else { return }
            scan.status = status.rawValue
            if let processedPath {
                scan.processedImagePath = processedPath
            } else if status == .error {
                scan.processedImagePath = nil
            }
            try context.save()
        } catch {
            statusText = "Scan update failed"
        }
    }

    @discardableResult
    func finishBatch() -> UUID? {
        guard let context else { return }
        guard let objectID = currentBatchObjectID,
              let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
            resetBatchSession()
            statusText = "Batch reset"
            return nil
        }

        batch.status = BatchStatus.queued.rawValue
        batch.updatedAt = Date()
        let finishedBatchId = batch.id

        do {
            try context.save()
            statusText = "Batch queued"
            ProcessingQueue.shared.enqueuePendingProcessing()
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

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let rawURL = try VaultScanStore.url(for: rawPath)
                let rawData = try Data(contentsOf: rawURL)
                let processed = try DocumentProcessingPipeline.process(imageData: rawData)
                let processedPath = try VaultScanStore.saveProcessedScan(
                    processedData: processed.processedData,
                    rawPath: rawPath
                )
                await MainActor.run {
                    self?.updateScanStatus(
                        forRawPath: rawPath,
                        status: .captured,
                        processedPath: processedPath
                    )
                    self?.statusText = "Retry complete"
                    self?.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self?.updateScanStatus(forRawPath: rawPath, status: .error, processedPath: nil)
                    self?.statusText = "Retry failed"
                    self?.isProcessing = false
                }
            }
        }
    }

    private func resetBatchSession() {
        batchId = UUID().uuidString
        pageIndex = 0
        scanCount = 0
        currentBatchObjectID = nil
    }

    private func fetchOrCreateBatch(in context: NSManagedObjectContext) throws -> BatchEntity {
        if let objectID = currentBatchObjectID,
           let existing = try? context.existingObject(with: objectID) as? BatchEntity {
            return existing
        }

        let notebook = try fetchOrCreateDefaultNotebook(in: context)
        let batch = BatchEntity(context: context)
        batch.id = UUID()
        batch.createdAt = Date()
        batch.status = BatchStatus.open.rawValue
        batch.notebook = notebook
        currentBatchObjectID = batch.objectID
        return batch
    }

    private func fetchOrCreateDefaultNotebook(in context: NSManagedObjectContext) throws -> NotebookEntity {
        let request = NotebookEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "isDefault == YES")
        if let notebook = try context.fetch(request).first {
            return notebook
        }

        let notebook = NotebookEntity(context: context)
        notebook.id = UUID()
        notebook.name = "Default"
        notebook.isDefault = true
        notebook.createdAt = Date()
        return notebook
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

    private let sessionQueue = DispatchQueue(label: "marginshot.camera.session")
    private let videoQueue = DispatchQueue(label: "marginshot.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false
    private var isDetecting = false
    private var lastDetectionTime: CFTimeInterval = 0

    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }
            do {
                try self.configureSession()
                self.isConfigured = true
            } catch {
                self.onSessionError?(error)
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.isHighResolutionCaptureEnabled {
            settings.isHighResolutionPhotoEnabled = true
        }
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraControllerError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        photoOutput.isHighResolutionCaptureEnabled = true

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
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

enum CameraControllerError: LocalizedError {
    case cameraUnavailable
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Camera unavailable"
        case .captureFailed:
            return "Capture failed"
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

struct StoredScan {
    let rawPath: String
    let processedPath: String?
}

enum VaultScanStore {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func saveScan(
        rawData: Data,
        processedData: Data?,
        batchId: String,
        pageIndex: Int
    ) throws -> StoredScan {
        let fileManager = FileManager.default
        let dateFolder = dateFormatter.string(from: Date())
        let relativeDirectory = "scans/\(dateFolder)/batch-\(batchId)"
        let vaultURL = try vaultRootURL()
        let directoryURL = vaultURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let rawFileName = String(format: "page-%03d-raw.jpg", pageIndex)
        let processedFileName = String(format: "page-%03d.jpg", pageIndex)
        let rawURL = directoryURL.appendingPathComponent(rawFileName)
        let processedURL = directoryURL.appendingPathComponent(processedFileName)

        try rawData.write(to: rawURL, options: .atomic)

        let rawPath = "\(relativeDirectory)/\(rawFileName)"
        var processedPath: String?
        if let processedData {
            try processedData.write(to: processedURL, options: .atomic)
            processedPath = "\(relativeDirectory)/\(processedFileName)"
        }

        return StoredScan(rawPath: rawPath, processedPath: processedPath)
    }

    static func saveProcessedScan(processedData: Data, rawPath: String) throws -> String {
        let processedPath = processedPath(from: rawPath)
        let processedURL = try url(for: processedPath)
        try processedData.write(to: processedURL, options: .atomic)
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
        return "\(trimmedBase).\(ext)"
    }

    private static func vaultRootURL() throws -> URL {
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
            return "Needs retry"
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
        case .error:
            return "Error"
        }
    }
}

extension ScanEntity {
    var statusEnum: ScanStatus? {
        ScanStatus(rawValue: status)
    }

    var statusLabel: String {
        statusEnum?.label ?? status.capitalized
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
    CaptureView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
