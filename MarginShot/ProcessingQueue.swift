import BackgroundTasks
import CoreData
import Foundation
import Network
import UIKit

struct ProcessingPreferences {
    var requiresWiFi: Bool {
        UserDefaults.standard.bool(forKey: "processingWiFiOnly")
    }

    var requiresExternalPower: Bool {
        UserDefaults.standard.bool(forKey: "processingRequiresCharging")
    }

    var qualityMode: ProcessingQualityMode {
        ProcessingQualityMode.load()
    }
}

struct ScanSnapshot {
    let id: UUID
    let batchId: UUID?
    let createdAt: Date
    let status: ScanStatus
    let imagePath: String
    let processedPath: String?
    let transcriptJSON: String?
    let structuredJSON: String?
    let ocrText: String?
    let structuredMarkdown: String?
}

struct VaultWriterInput {
    let scanId: UUID
    let batchId: UUID?
    let capturedAt: Date
    let imagePath: String
    let processedImagePath: String?
    let transcript: TranscriptionPayload
    let transcriptJSON: String?
    let structured: StructurePayload
    let structuredJSON: String?
}

struct VaultWriteResult {
    let notePath: String
    let noteTitle: String
    let metadataPath: String
}

struct ScanMetadata: Codable {
    let scanId: String
    let batchId: String?
    let capturedAt: String
    let imagePath: String
    let processedImagePath: String?
    let notePath: String
    let noteTitle: String
    let transcript: TranscriptionPayload
    let structured: StructurePayload
    let transcriptJSON: String?
    let structuredJSON: String?
}

enum VaultWriterError: Error {
    case documentsDirectoryUnavailable
    case invalidPayload
}

enum VaultWriter {
    private static let fileManager = FileManager.default
    private static let dailyFolder = "01_daily"
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func apply(input: VaultWriterInput) throws -> VaultWriteResult {
        let rootURL = try vaultRootURL()
        let folder = input.structured.classification.folder
        let noteResult = try writeNote(input: input, rootURL: rootURL, folder: folder)
        let metadataPath = metadataPath(for: input.processedImagePath ?? input.imagePath)
        let metadataURL = rootURL.appendingPathComponent(metadataPath)
        let metadata = ScanMetadata(
            scanId: input.scanId.uuidString,
            batchId: input.batchId?.uuidString,
            capturedAt: isoFormatter.string(from: input.capturedAt),
            imagePath: input.imagePath,
            processedImagePath: input.processedImagePath,
            notePath: noteResult.path,
            noteTitle: noteResult.title,
            transcript: input.transcript,
            structured: input.structured,
            transcriptJSON: input.transcriptJSON,
            structuredJSON: input.structuredJSON
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)
        try writeAtomically(data: metadataData, to: metadataURL)
        return VaultWriteResult(notePath: noteResult.path, noteTitle: noteResult.title, metadataPath: metadataPath)
    }

    private static func writeNote(input: VaultWriterInput, rootURL: URL, folder: String) throws -> (path: String, title: String) {
        let directoryURL = rootURL.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        if folder == dailyFolder {
            let dateString = dateFormatter.string(from: input.capturedAt)
            let fileName = "\(dateString).md"
            let notePath = "\(folder)/\(fileName)"
            let noteURL = rootURL.appendingPathComponent(notePath)
            let entry = buildDailyEntry(input: input)
            let updated = try appendDailyEntry(existingAt: noteURL, dateString: dateString, entry: entry)
            try writeAtomically(text: updated, to: noteURL)
            return (notePath, dateString)
        }

        let baseName = sanitizeFileName(input.structured.noteMeta.title)
        let fileName = uniqueFileName(baseName: baseName, in: directoryURL)
        let notePath = "\(folder)/\(fileName)"
        let noteURL = rootURL.appendingPathComponent(notePath)
        let content = buildNoteContent(input: input)
        try writeAtomically(text: content, to: noteURL)
        return (notePath, input.structured.noteMeta.title)
    }

    private static func buildDailyEntry(input: VaultWriterInput) -> String {
        let title = input.structured.noteMeta.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryTitle = title.isEmpty ? "Scan Notes" : title
        let timestamp = timeFormatter.string(from: input.capturedAt)
        var entry = "## \(entryTitle)\n"
        entry += "Captured: \(timestamp)\n"
        if let batchId = input.batchId?.uuidString {
            entry += "Batch: \(batchId)\n"
        }
        entry += "Scan: \(input.scanId.uuidString)\n\n"
        entry += normalizedMarkdown(input.structured.markdown)
        if shouldAppendRawTranscript(to: input.structured.markdown) {
            entry += "\n\n### Raw transcription\n"
            entry += input.transcript.rawTranscript
        }
        return entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendDailyEntry(existingAt url: URL, dateString: String, entry: String) throws -> String {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing.isEmpty {
            return "# \(dateString)\n\n\(entry)\n"
        }

        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSeparator = trimmed.contains("\n## ")
        var updated = existing
        if needsSeparator {
            updated += "\n\n---\n\n"
        } else if !updated.hasSuffix("\n\n") {
            updated += "\n\n"
        }
        updated += entry
        if !updated.hasSuffix("\n") {
            updated += "\n"
        }
        return updated
    }

    private static func buildNoteContent(input: VaultWriterInput) -> String {
        var content = normalizedMarkdown(input.structured.markdown)
        if shouldAppendRawTranscript(to: input.structured.markdown) {
            content += "\n\n## Raw transcription\n"
            content += input.transcript.rawTranscript
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func normalizedMarkdown(_ markdown: String) -> String {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldAppendRawTranscript(to markdown: String) -> Bool {
        let lowercased = markdown.lowercased()
        return !lowercased.contains("raw transcription") && !lowercased.contains("raw transcript")
    }

    private static func metadataPath(for imagePath: String) -> String {
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

    private static func sanitizeFileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let mapped = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let raw = String(mapped)
        let dashed = raw.replacingOccurrences(of: " ", with: "-")
        var collapsed = dashed
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "note" : trimmed
    }

    private static func uniqueFileName(baseName: String, in directory: URL) -> String {
        var candidate = "\(baseName).md"
        var index = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(index).md"
            index += 1
        }
        return candidate
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultWriterError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    private static func writeAtomically(text: String, to url: URL) throws {
        try writeAtomically(data: Data(text.utf8), to: url)
    }

    private static func writeAtomically(data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }
}

final class ProcessingQueue {
    static let shared = ProcessingQueue()

    private let persistenceController: PersistenceController
    private let taskIdentifier = "com.example.MarginShot.processing"
    private let processingQueue = DispatchQueue(label: "marginshot.processing.queue")
    private var isProcessing = false

    private var preferences: ProcessingPreferences {
        ProcessingPreferences()
    }

    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
            self?.handleBackgroundTask(task)
        }
    }

    func enqueuePendingProcessing() {
        scheduleBackgroundProcessing()
        processPendingBatchesIfNeeded()
    }

    func scheduleBackgroundProcessing() {
        let prefs = preferences
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
            guard let self else { return }
            guard !requests.contains(where: { $0.identifier == self.taskIdentifier }) else { return }

            let request = BGProcessingTaskRequest(identifier: self.taskIdentifier)
            request.requiresNetworkConnectivity = prefs.requiresWiFi
            request.requiresExternalPower = prefs.requiresExternalPower

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("Failed to schedule processing task: \(error)")
            }
        }
    }

    private func handleBackgroundTask(_ task: BGTask) {
        scheduleBackgroundProcessing()
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        let processing = Task { [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let success = await self.processPendingBatches()
            task.setTaskCompleted(success: success)
        }

        processingTask.expirationHandler = {
            processing.cancel()
        }
    }

    private func processPendingBatchesIfNeeded() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isProcessing else { return }
            self.isProcessing = true
            Task {
                _ = await self.processPendingBatches()
                self.processingQueue.async { [weak self] in
                    self?.isProcessing = false
                }
            }
        }
    }

    private func hasRequiredPower() async -> Bool {
        let prefs = preferences
        guard prefs.requiresExternalPower else { return true }
        return await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }
    }

    private func hasRequiredNetwork() async -> Bool {
        let prefs = preferences
        guard prefs.requiresWiFi else { return true }
        return await NetworkConstraintChecker.isWiFiAvailable()
    }

    private func processPendingBatches() async -> Bool {
        guard await hasRequiredPower() else {
            scheduleBackgroundProcessing()
            return false
        }
        guard await hasRequiredNetwork() else {
            scheduleBackgroundProcessing()
            return false
        }

        let context = persistenceController.container.newBackgroundContext()
        let batchIDs: [NSManagedObjectID] = await context.perform {
            let request = BatchEntity.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", BatchStatus.queued.rawValue)
            request.sortDescriptors = [
                NSSortDescriptor(key: "notebook.id", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true)
            ]
            do {
                return try context.fetch(request).map { $0.objectID }
            } catch {
                print("Failed to fetch queued batches: \(error)")
                return []
            }
        }

        guard !batchIDs.isEmpty else { return true }

        let client: GeminiClient
        do {
            client = try GeminiClient.makeDefault()
        } catch {
            await markBatchesFailed(batchIDs, context: context)
            return false
        }

        let processingContext = ProcessingContextLoader.load()
        let mode = preferences.qualityMode
        var allSucceeded = true
        for objectID in batchIDs {
            if Task.isCancelled { return false }
            let success = await processBatch(
                objectID: objectID,
                context: context,
                client: client,
                mode: mode,
                processingContext: processingContext
            )
            if !success {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    private func processBatch(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        client: GeminiClient,
        mode: ProcessingQualityMode,
        processingContext: ProcessingContextSnapshot
    ) async -> Bool {
        let scanIDs: [NSManagedObjectID] = await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
                return []
            }
            batch.status = BatchStatus.processing.rawValue
            batch.updatedAt = Date()
            do {
                try context.save()
            } catch {
                return []
            }
            return batch.scans.map { $0.objectID }
        }

        var batchSucceeded = true
        for scanID in scanIDs {
            if Task.isCancelled { return false }
            let success = await processScan(
                objectID: scanID,
                context: context,
                client: client,
                mode: mode,
                processingContext: processingContext
            )
            if !success {
                batchSucceeded = false
            }
        }

        let hasScanError = await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
                return true
            }
            return batch.scans.contains { ScanStatus(rawValue: $0.status) == .error }
        }

        await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { return }
            batch.status = hasScanError ? BatchStatus.error.rawValue : BatchStatus.done.rawValue
            batch.updatedAt = Date()
            try? context.save()
        }

        return batchSucceeded && !hasScanError
    }

    private func processScan(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        client: GeminiClient,
        mode: ProcessingQualityMode,
        processingContext: ProcessingContextSnapshot
    ) async -> Bool {
        guard let snapshot = await loadScanSnapshot(objectID: objectID, context: context) else {
            return false
        }

        switch snapshot.status {
        case .filed:
            return true
        case .error:
            return false
        case .structured:
            do {
                let writerInput = try writerInput(from: snapshot)
                return await fileStructuredScan(objectID: objectID, context: context, writerInput: writerInput)
            } catch {
                await markScanError(objectID: objectID, context: context)
                return false
            }
        default:
            break
        }

        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
            scan.status = ScanStatus.transcribing.rawValue
            try? context.save()
        }

        do {
            let input = try loadScanInput(imagePath: snapshot.processedPath ?? snapshot.imagePath)
            let output = try await ScanProcessingPipeline.process(
                input: input,
                mode: mode,
                client: client,
                context: processingContext
            )
            guard let writerInput = await persistStructuredOutput(
                objectID: objectID,
                context: context,
                output: output
            ) else {
                return false
            }
            return await fileStructuredScan(objectID: objectID, context: context, writerInput: writerInput)
        } catch {
            await markScanError(objectID: objectID, context: context)
            return false
        }
    }

    private func loadScanSnapshot(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext
    ) async -> ScanSnapshot? {
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else {
                return nil
            }
            guard let status = ScanStatus(rawValue: scan.status) else {
                return nil
            }
            return ScanSnapshot(
                id: scan.id,
                batchId: scan.batch?.id,
                createdAt: scan.createdAt,
                status: status,
                imagePath: scan.imagePath,
                processedPath: scan.processedImagePath,
                transcriptJSON: scan.transcriptJSON,
                structuredJSON: scan.structuredJSON,
                ocrText: scan.ocrText,
                structuredMarkdown: scan.structuredMarkdown
            )
        }
    }

    private func persistStructuredOutput(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        output: ScanProcessingOutput
    ) async -> VaultWriterInput? {
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else {
                return nil
            }
            scan.ocrText = output.transcript.rawTranscript
            scan.confidence = output.transcript.confidence.map { NSNumber(value: $0) }
            scan.transcriptJSON = output.transcriptJSON
            scan.structuredMarkdown = output.structured.markdown
            scan.structuredJSON = output.structuredJSON
            scan.status = ScanStatus.structured.rawValue
            try? context.save()
            return VaultWriterInput(
                scanId: scan.id,
                batchId: scan.batch?.id,
                capturedAt: scan.createdAt,
                imagePath: scan.imagePath,
                processedImagePath: scan.processedImagePath,
                transcript: output.transcript,
                transcriptJSON: output.transcriptJSON,
                structured: output.structured,
                structuredJSON: output.structuredJSON
            )
        }
    }

    private func writerInput(from snapshot: ScanSnapshot) throws -> VaultWriterInput {
        let decoder = JSONDecoder()
        guard let structuredJSON = snapshot.structuredJSON ?? snapshot.transcriptJSON,
              let structuredData = structuredJSON.data(using: .utf8) else {
            throw VaultWriterError.invalidPayload
        }
        let structured = try decoder.decode(StructurePayload.self, from: structuredData)

        let transcriptJSON = snapshot.transcriptJSON ?? structuredJSON
        guard let transcriptData = transcriptJSON.data(using: .utf8) else {
            throw VaultWriterError.invalidPayload
        }
        let transcript = try decoder.decode(TranscriptionPayload.self, from: transcriptData)

        return VaultWriterInput(
            scanId: snapshot.id,
            batchId: snapshot.batchId,
            capturedAt: snapshot.createdAt,
            imagePath: snapshot.imagePath,
            processedImagePath: snapshot.processedPath,
            transcript: transcript,
            transcriptJSON: snapshot.transcriptJSON ?? structuredJSON,
            structured: structured,
            structuredJSON: structuredJSON
        )
    }

    private func fileStructuredScan(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        writerInput: VaultWriterInput
    ) async -> Bool {
        do {
            let result = try VaultWriter.apply(input: writerInput)
            await context.perform {
                guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
                scan.status = ScanStatus.filed.rawValue
                try? context.save()
            }
            await upsertNoteEntity(
                context: context,
                notePath: result.notePath,
                noteTitle: result.noteTitle,
                noteMeta: writerInput.structured.noteMeta
            )
            await VaultIndexStore.shared.updateAfterNoteWrite(
                notePath: result.notePath,
                noteTitle: result.noteTitle,
                noteMeta: writerInput.structured.noteMeta,
                context: context
            )
            return true
        } catch {
            await markScanError(objectID: objectID, context: context)
            return false
        }
    }

    private func upsertNoteEntity(
        context: NSManagedObjectContext,
        notePath: String,
        noteTitle: String,
        noteMeta: NoteMeta
    ) async {
        await context.perform {
            let request = NoteEntity.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "path == %@", notePath)
            let now = Date()
            if let existing = try? context.fetch(request).first {
                existing.title = noteTitle
                existing.summary = noteMeta.summary
                existing.tags = noteMeta.tags
                existing.links = noteMeta.links
                existing.updatedAt = now
            } else {
                let note = NoteEntity(context: context)
                note.id = UUID()
                note.path = notePath
                note.title = noteTitle
                note.summary = noteMeta.summary
                note.tags = noteMeta.tags
                note.links = noteMeta.links
                note.createdAt = now
                note.updatedAt = now
            }
            try? context.save()
        }
    }

    private func markScanError(objectID: NSManagedObjectID, context: NSManagedObjectContext) async {
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
            scan.status = ScanStatus.error.rawValue
            try? context.save()
        }
    }

    private func loadScanInput(imagePath: String) throws -> ScanProcessingInput {
        let url = try VaultScanStore.url(for: imagePath)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw ProcessingPipelineError.invalidImageData
        }
        return ScanProcessingInput(imageData: data, mimeType: mimeType(for: imagePath))
    }

    private func mimeType(for path: String) -> String {
        let lowercased = (path as NSString).pathExtension.lowercased()
        switch lowercased {
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        default:
            return "image/jpeg"
        }
    }

    private func markBatchesFailed(_ batchIDs: [NSManagedObjectID], context: NSManagedObjectContext) async {
        await context.perform {
            for objectID in batchIDs {
                guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { continue }
                batch.status = BatchStatus.error.rawValue
                batch.updatedAt = Date()
                for scan in batch.scans {
                    if ScanStatus(rawValue: scan.status) != .filed {
                        scan.status = ScanStatus.error.rawValue
                    }
                }
            }
            try? context.save()
        }
    }
}

enum NetworkConstraintChecker {
    static func isWiFiAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "marginshot.network.monitor")
            monitor.pathUpdateHandler = { path in
                let satisfied = path.status == .satisfied && path.usesInterfaceType(.wifi)
                monitor.cancel()
                continuation.resume(returning: satisfied)
            }
            monitor.start(queue: queue)
        }
    }
}
