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
        let scanInfo: (status: ScanStatus, imagePath: String, processedPath: String?)? = await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else {
                return nil
            }
            guard let status = ScanStatus(rawValue: scan.status) else {
                return nil
            }
            return (status, scan.imagePath, scan.processedImagePath)
        }

        guard let scanInfo else { return false }
        guard scanInfo.status != .structured, scanInfo.status != .filed else { return true }
        guard scanInfo.status != .error else { return false }

        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
            scan.status = ScanStatus.transcribing.rawValue
            try? context.save()
        }

        do {
            let input = try loadScanInput(imagePath: scanInfo.processedPath ?? scanInfo.imagePath)
            let output = try await ScanProcessingPipeline.process(
                input: input,
                mode: mode,
                client: client,
                context: processingContext
            )
            await context.perform {
                guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
                scan.ocrText = output.transcript.rawTranscript
                scan.confidence = output.transcript.confidence.map { NSNumber(value: $0) }
                scan.transcriptJSON = output.transcriptJSON
                scan.structuredMarkdown = output.structured.markdown
                scan.structuredJSON = output.structuredJSON
                scan.status = ScanStatus.structured.rawValue
                try? context.save()
            }
            return true
        } catch {
            await context.perform {
                guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
                scan.status = ScanStatus.error.rawValue
                try? context.save()
            }
            return false
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
