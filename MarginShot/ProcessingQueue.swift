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

        var allSucceeded = true
        for objectID in batchIDs {
            if Task.isCancelled { return false }
            let success = await context.perform {
                guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
                    return false
                }
                batch.status = BatchStatus.processing.rawValue
                batch.updatedAt = Date()
                BatchProcessingPipeline.process(batch: batch)

                let hasScanError = batch.scans.contains { ScanStatus(rawValue: $0.status) == .error }
                batch.status = hasScanError ? BatchStatus.error.rawValue : BatchStatus.done.rawValue
                batch.updatedAt = Date()

                do {
                    try context.save()
                    return !hasScanError
                } catch {
                    return false
                }
            }
            if !success {
                allSucceeded = false
            }
        }
        return allSucceeded
    }
}

enum BatchProcessingPipeline {
    static func process(batch: BatchEntity) {
        for scan in batch.scans {
            guard let status = ScanStatus(rawValue: scan.status) else { continue }
            switch status {
            case .captured, .preprocessing, .transcribing:
                scan.status = ScanStatus.structured.rawValue
            case .structured, .filed, .error:
                break
            }
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
