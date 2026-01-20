import CoreData
import Foundation
import SwiftUI

@main
struct MarginShotApp: App {
    private let persistenceController = PersistenceController.shared
    @StateObject private var syncStatus = SyncStatusStore.shared

    init() {
        configureUITesting()
        ProcessingQueue.shared.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(syncStatus)
        }
    }

    private func configureUITesting() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return }
        let defaults = UserDefaults.standard
        if arguments.contains("-ui-testing-reset") {
            defaults.set(false, forKey: "hasCompletedOnboarding")
        }
        if arguments.contains("-ui-testing-complete-onboarding") {
            defaults.set(true, forKey: "hasCompletedOnboarding")
        }
    }
}
