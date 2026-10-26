import CoreData
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureRecord: Codable {
    let scanID: UUID
    let batchID: UUID
    let notebookID: UUID?
    let createdAt: Date
    let pageNumber: Int
    let rawPath: String
}

enum CaptureStoreError: Error { case metadataUnavailable, missingOriginal, unsupportedImage }

enum CaptureImageFormat: String {
    case jpeg = "jpg", png, heic

    static func validated(_ data: Data) throws -> CaptureImageFormat {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let identifier = CGImageSourceGetType(source) else { throw CaptureStoreError.unsupportedImage }
        switch identifier as String {
        case UTType.jpeg.identifier: return .jpeg
        case UTType.png.identifier: return .png
        case UTType.heic.identifier: return .heic
        default: throw CaptureStoreError.unsupportedImage
        }
    }
}

final class CaptureStore: @unchecked Sendable {
    enum Checkpoint { case placed, metadataSaved }
    let rootURL: URL
    let userDefaults: UserDefaults
    var checkpoint: ((Checkpoint) throws -> Void)?

    init(rootURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("vault", isDirectory: true)
        self.userDefaults = userDefaults
        VaultRepository.register(rootURL: self.rootURL, userDefaults: userDefaults)
    }

    func placeOriginal(_ data: Data, batchID: UUID, notebookID: UUID?, pageNumber: Int, scanID: UUID = UUID(), createdAt: Date = Date(), format: CaptureImageFormat = .jpeg) throws -> CaptureRecord {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = "scans/\(formatter.string(from: createdAt))/batch-\(batchID.uuidString)"
        let record = CaptureRecord(scanID: scanID, batchID: batchID, notebookID: notebookID, createdAt: createdAt, pageNumber: pageNumber, rawPath: "\(directory)/\(String(format: "page-%03d-", pageNumber) + scanID.uuidString + "-raw.\(format.rawValue)")")
        let repository = VaultRepository.register(rootURL: rootURL, userDefaults: userDefaults)
        let saved: CaptureRecord = try repository.transaction(id: "capture:\(scanID.uuidString)") {
            try VaultFileStore.writeData(data, to: self.rootURL.appendingPathComponent(record.rawPath), userDefaults: self.userDefaults)
            let intentURL = self.rootURL.appendingPathComponent(directory).appendingPathComponent("capture-\(scanID.uuidString).json")
            try VaultFileStore.writeData(JSONEncoder().encode(record), to: intentURL, userDefaults: self.userDefaults)
            return record
        }
        try checkpoint?(.placed)
        return saved
    }

    func persist(_ record: CaptureRecord, in context: NSManagedObjectContext) throws {
        guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(record.rawPath).path) else { throw CaptureStoreError.missingOriginal }
        try context.performAndWait {
            let request = ScanEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", record.scanID as CVarArg)
            request.fetchLimit = 1
            if try context.fetch(request).first != nil {
                if context.hasChanges { try context.save() }
                return
            }
            let batches = BatchEntity.fetchRequest()
            batches.predicate = NSPredicate(format: "id == %@", record.batchID as CVarArg)
            batches.fetchLimit = 1
            let batch: BatchEntity
            if let existing = try context.fetch(batches).first { batch = existing }
            else {
                batch = BatchEntity(context: context)
                batch.id = record.batchID
                batch.createdAt = record.createdAt
                batch.status = BatchStatus.open.rawValue
                let notebooks = NotebookEntity.fetchRequest()
                if let id = record.notebookID { notebooks.predicate = NSPredicate(format: "id == %@", id as CVarArg) }
                else { notebooks.predicate = NSPredicate(format: "isDefault == YES") }
                notebooks.fetchLimit = 1
                if let notebook = try context.fetch(notebooks).first { batch.notebook = notebook }
                else {
                    let notebook = NotebookEntity(context: context)
                    notebook.id = record.notebookID ?? UUID()
                    notebook.name = "Default"
                    notebook.createdAt = record.createdAt
                    notebook.isDefault = true
                    batch.notebook = notebook
                }
            }
            let scan = ScanEntity(context: context)
            scan.id = record.scanID
            scan.createdAt = record.createdAt
            scan.status = ScanStatus.preprocessing.rawValue
            scan.imagePath = record.rawPath
            scan.pageNumber = NSNumber(value: record.pageNumber)
            scan.batch = batch
            scan.jobState = ProcessingJobState.pending.rawValue
            scan.jobCheckpoint = "original"
            scan.jobAttempts = 0
            try context.save()
        }
        try checkpoint?(.metadataSaved)
    }

    func finishBatch(_ batchID: UUID, in context: NSManagedObjectContext) throws -> UUID {
        try context.performAndWait {
            let request = BatchEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", batchID as CVarArg)
            guard let batch = try context.fetch(request).first else { throw CaptureStoreError.metadataUnavailable }
            batch.status = BatchStatus.queued.rawValue
            batch.updatedAt = Date()
            try context.save()
            return batch.id
        }
    }

    /// Invoke once at startup, before exposing a live capture session.
    func recover(context: NSManagedObjectContext) throws {
        let repository = VaultRepository.register(rootURL: rootURL, userDefaults: userDefaults)
        try repository.recover()
        let scans = rootURL.appendingPathComponent("scans", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: scans, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("capture-") && url.pathExtension == "json" {
                let record = try JSONDecoder().decode(CaptureRecord.self, from: VaultFileStore.readData(from: url, userDefaults: userDefaults))
                try persist(record, in: context)
            }
        }
        try ProcessingJobStore.recover(context: context)
    }
}

enum ProcessingJobState: String {
    case pending, running, paused, retryScheduled, needsAttention, complete
}

enum ProcessingJobStore {
    static func recover(context: NSManagedObjectContext) throws {
        try context.performAndWait {
            for scan in try context.fetch(ScanEntity.fetchRequest()) {
                let status = ScanStatus(rawValue: scan.status)
                if status == .filed {
                    scan.jobState = ProcessingJobState.complete.rawValue
                    scan.jobCheckpoint = "filed"
                } else if scan.jobState == nil && status == .structured {
                    // Old non-daily writes have no idempotency receipt. Preserve output for explicit review.
                    scan.jobState = ProcessingJobState.needsAttention.rawValue
                    scan.jobCheckpoint = "structured"
                    scan.jobFailure = "legacyFilingNeedsReview"
                } else if scan.jobState == nil || scan.jobState == ProcessingJobState.running.rawValue {
                    scan.jobState = status == .error ? ProcessingJobState.needsAttention.rawValue : ProcessingJobState.pending.rawValue
                    if scan.jobCheckpoint == nil {
                        scan.jobCheckpoint = status == .structured ? "structured" : (scan.processedImagePath == nil ? "original" : "inputReady")
                    }
                    if status == .transcribing { scan.status = ScanStatus.captured.rawValue }
                }
                if scan.jobAttempts == nil { scan.jobAttempts = 0 }
            }
            for batch in try context.fetch(BatchEntity.fetchRequest()) {
                if batch.status == BatchStatus.processing.rawValue || batch.status == BatchStatus.open.rawValue {
                    batch.status = BatchStatus.queued.rawValue
                    batch.updatedAt = Date()
                }
            }
            try context.save()
        }
    }

    static func pause(scan: ScanEntity, category: String) {
        scan.jobState = ProcessingJobState.paused.rawValue
        scan.jobFailure = category
        scan.status = scan.jobCheckpoint == "structured" ? ScanStatus.structured.rawValue : ScanStatus.captured.rawValue
    }
}

actor AppRecovery {
    static let shared = AppRecovery()
    private var task: Task<Void, Error>?

    func prepare() async throws {
        if task == nil {
            task = Task {
                let controller = PersistenceController.shared
                try await controller.load()
                try await Task.detached {
                    try VaultEncryptionManager.validateExistingKey()
                    try VaultBootstrapper.bootstrapIfNeeded()
                    try CaptureStore().recover(context: controller.container.newBackgroundContext())
                    try VaultEncryptionManager.prepareVault()
                }.value
            }
        }
        try await task!.value
    }
}
