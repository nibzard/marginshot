import CoreData
import SwiftUI

@main
struct MarginShotApp: App {
    private let persistenceController = PersistenceController.shared
    @StateObject private var syncStatus = SyncStatusStore.shared

    init() {
        ProcessingQueue.shared.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(syncStatus)
        }
    }
}
