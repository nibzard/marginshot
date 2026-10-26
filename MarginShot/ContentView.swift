import CoreData
import Foundation
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case capture
    case library
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture:
            return "Capture"
        case .library:
            return "Library"
        case .chat:
            return "Chat"
        }
    }
}

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedMode: AppMode = .capture
    @State private var preferredBatchId: UUID?
    @State private var importRequested = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.themeColors) private var theme
    @EnvironmentObject private var syncStatus: SyncStatusStore

    var body: some View {
        ZStack {
            theme.backgroundGradient
                .ignoresSafeArea()
            if hasCompletedOnboarding {
                TabView(selection: $selectedMode) {
                    NavigationStack {
                        CaptureView(mode: $selectedMode, importRequested: $importRequested) { batchId in
                            preferredBatchId = batchId
                            selectedMode = .chat
                        }
                        .navigationTitle("Capture")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem { Label("Capture", systemImage: "camera") }
                    .tag(AppMode.capture)
                    NavigationStack {
                        LibraryView(mode: $selectedMode, importRequested: $importRequested)
                    }
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(AppMode.library)
                    NavigationStack {
                        ChatView(mode: $selectedMode, preferredBatchId: $preferredBatchId)
                            .navigationTitle("Chat")
                    }
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(AppMode.chat)
                }
                .tint(theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                OnboardingView(isComplete: $hasCompletedOnboarding) { importRequested = true }
            }
        }
        .onAppear {
            if DesignFixture.current == nil { syncStatus.refreshDestination() }
            if DesignFixture.current == nil { VaultFileStore.cleanupDecryptedCopies() }
        }
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding, DesignFixture.current == nil else { return }
            let bootstrapStart = CFAbsoluteTimeGetCurrent()
            print("⏱️ [PERF] Starting vault bootstrap...")
            Task.detached {
                do {
                    let bootStart = CFAbsoluteTimeGetCurrent()
                    try await Task.detached {
                        try VaultBootstrapper.bootstrapIfNeeded()
                    }.value
                    let bootTime = (CFAbsoluteTimeGetCurrent() - bootStart) * 1000
                    print("⏱️ [PERF] VaultBootstrapper.bootstrapIfNeeded took \(bootTime)ms")

                    await MainActor.run {
                        let encStart = CFAbsoluteTimeGetCurrent()
                        VaultEncryptionManager.startIfNeeded()
                        let encTime = (CFAbsoluteTimeGetCurrent() - encStart) * 1000
                        print("⏱️ [PERF] VaultEncryptionManager.startIfNeeded took \(encTime)ms")

                        let queueStart = CFAbsoluteTimeGetCurrent()
                        ProcessingQueue.shared.enqueuePendingProcessing()
                        let queueTime = (CFAbsoluteTimeGetCurrent() - queueStart) * 1000
                        print("⏱️ [PERF] ProcessingQueue.enqueuePendingProcessing took \(queueTime)ms")

                        let totalTime = (CFAbsoluteTimeGetCurrent() - bootstrapStart) * 1000
                        print("⏱️ [PERF] TOTAL ContentView task took \(totalTime)ms")
                    }
                } catch {
                    print("Vault bootstrap failed: \(error)")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if DesignFixture.current == nil { VaultFileStore.cleanupDecryptedCopies() }
            }
            guard hasCompletedOnboarding, DesignFixture.current == nil else { return }
            switch phase {
            case .active:
                ProcessingQueue.shared.enqueuePendingProcessing()
            case .background:
                ProcessingQueue.shared.scheduleBackgroundProcessing()
                SyncBackgroundScheduler.schedule()
            default:
                break
            }
        }
    }
}

struct VaultBootstrapper {
    private static let vaultFolderName = "vault"

    static func bootstrapIfNeeded(userDefaults: UserDefaults = .standard, rootURL: URL? = nil) throws {
        let rootURL = try rootURL ?? vaultRootURL()
        let repository = VaultRepository.register(rootURL: rootURL, userDefaults: userDefaults)
        try repository.recover()
        try createDirectoryIfNeeded(at: rootURL)
        let style = OrganizationPreferences(userDefaults: userDefaults).style

        for directory in vaultDirectories(style: style) {
            let directoryURL = rootURL.appendingPathComponent(directory, isDirectory: true)
            try createDirectoryIfNeeded(at: directoryURL)
        }

        let systemDirectoryURL = rootURL.appendingPathComponent("_system", isDirectory: true)
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("SYSTEM.md"),
            contents: SystemRulesStore.defaultRules,
            userDefaults: userDefaults
        )
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("INDEX.json"),
            contents: defaultIndexJSON,
            userDefaults: userDefaults
        )
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("STRUCTURE.txt"),
            contents: defaultStructureText(style: style),
            userDefaults: userDefaults
        )
    }

    private static func vaultRootURL() throws -> URL {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultBootstrapError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent(vaultFolderName, isDirectory: true)
    }

    private static func createDirectoryIfNeeded(at url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    private static func writeFileIfNeeded(at url: URL, contents: String, userDefaults: UserDefaults) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try VaultFileStore.writeText(contents, to: url, userDefaults: userDefaults)
    }

    private static let defaultIndexJSON = """
    {
      "notes": []
    }
    """

    private static func vaultDirectories(style: OrganizationStyle) -> [String] {
        VaultFolder.folderNames(style: style) + ["_topics", "_system", "scans"]
    }

    private static func defaultStructureText(style: OrganizationStyle) -> String {
        var lines: [String] = ["vault/"]
        for folder in VaultFolder.folderNames(style: style) {
            lines.append("\(folder)/")
        }
        lines.append("_topics/")
        lines.append("_system/")
        lines.append("scans/")
        return lines.joined(separator: "\n") + "\n"
    }
}

enum VaultBootstrapError: Error {
    case documentsDirectoryUnavailable
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(SyncStatusStore.shared)
}
