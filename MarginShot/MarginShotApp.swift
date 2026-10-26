// ABOUTME: MarginShot main app entry point
// ABOUTME: Configures Core Data, sync status, and background task registration

import CoreData
import Foundation
import SwiftUI

@main
struct MarginShotApp: App {
    @StateObject private var syncStatus = SyncStatusStore.shared
    @State private var persistenceController: PersistenceController?
    @State private var isCoreDataLoaded = false

    init() {
        let startTime = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        setenv("CG_NUMERICS_SHOW_BACKTRACE", "1", 1)
        #endif
        configureUITesting()
        if DesignFixture.current == nil && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            ProcessingQueue.shared.registerBackgroundTasks()
            SyncBackgroundScheduler.register()
        }
        let initTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("⏱️ [PERF] MarginShotApp.init took \(initTime)ms")
    }

    var body: some Scene {
        WindowGroup {
            let startTime = CFAbsoluteTimeGetCurrent()
            rootView(startTime: startTime)
                .themed()
        }
    }

    @ViewBuilder
    private func rootView(startTime: CFAbsoluteTime) -> some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Color.clear
        } else if let fixture = DesignFixture.current {
            DesignFixtureRoot(fixture: fixture)
                .environmentObject(syncStatus)
        } else if isCoreDataLoaded, let controller = persistenceController {
            ContentView()
                .environment(\.managedObjectContext, controller.container.viewContext)
                .environmentObject(syncStatus)
                .onAppear {
                    let bodyTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    print("⏱️ [PERF] ContentView appeared (body eval: \(bodyTime)ms)")
                }
        } else {
            LoadingView(onLoaded: { controller in
                persistenceController = controller
                isCoreDataLoaded = true
            })
                .onAppear {
                    let appearTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    print("⏱️ [PERF] RootView appeared (body eval: \(appearTime)ms)")
                }
        }
    }

    private func configureUITesting() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), DesignFixture.current == nil else { return }
        let defaults = UserDefaults.standard
        if arguments.contains("-ui-testing-reset") {
            defaults.set(false, forKey: "hasCompletedOnboarding")
        }
        if arguments.contains("-ui-testing-complete-onboarding") {
            defaults.set(true, forKey: "hasCompletedOnboarding")
        }
    }
}

private struct LoadingView: View {
    let onLoaded: (PersistenceController) -> Void
    @State private var hasAppeared = false
    @State private var recoveryError: String?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(AppTheme.accent)

            Text(recoveryError == nil ? "Loading MarginShot…" : "Vault needs attention")
                .font(AppTypography.callout)
                .foregroundStyle(AppTheme.ink)
            if let recoveryError {
                Text(recoveryError)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
                Text("Your vault and recovery copies have been preserved. Resolve the storage issue, then reopen MarginShot.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.backgroundTop)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            print("⏱️ [PERF] LoadingView appeared")
            Task {
                await loadCoreData()
            }
        }
    }

    private func loadCoreData() async {
        let loadStart = CFAbsoluteTimeGetCurrent()
        print("⏱️ [PERF] Starting Core Data load...")

        let controllerStart = CFAbsoluteTimeGetCurrent()
        let controller = PersistenceController.shared
        let controllerTime = (CFAbsoluteTimeGetCurrent() - controllerStart) * 1000
        print("⏱️ [PERF] PersistenceController.shared creation took \(controllerTime)ms")

        let storeLoadStart = CFAbsoluteTimeGetCurrent()
        do {
            try await AppRecovery.shared.prepare()
            let storeLoadTime = (CFAbsoluteTimeGetCurrent() - storeLoadStart) * 1000
            print("⏱️ [PERF] Core Data store load took \(storeLoadTime)ms")

            let bgTaskStart = CFAbsoluteTimeGetCurrent()
            await MainActor.run {
                SyncWakeupObserver.shared.start()
                let bgTaskTime = (CFAbsoluteTimeGetCurrent() - bgTaskStart) * 1000
                print("⏱️ [PERF] Background task registration took \(bgTaskTime)ms")

                let totalTime = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                print("⏱️ [PERF] TOTAL startup pipeline took \(totalTime)ms")

                onLoaded(controller)
            }
        } catch {
            recoveryError = error.localizedDescription
        }
    }
}
