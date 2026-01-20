import CoreData
import Foundation
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case capture
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture:
            return "Capture"
        case .chat:
            return "Chat"
        }
    }
}

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedMode: AppMode = .capture
    @State private var preferredBatchId: UUID?
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var syncStatus: SyncStatusStore

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                VStack(spacing: 0) {
                    HeaderView(mode: selectedMode, syncState: syncStatus.state)
                    TabView(selection: $selectedMode) {
                        CaptureView { batchId in
                            preferredBatchId = batchId
                            selectedMode = .chat
                        }
                            .tag(AppMode.capture)
                        ChatView(preferredBatchId: $preferredBatchId)
                            .tag(AppMode.chat)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .animation(.easeInOut(duration: 0.2), value: selectedMode)
            } else {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            }
        }
        .onAppear {
            syncStatus.refreshDestination()
        }
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding else { return }
            do {
                try VaultBootstrapper.bootstrapIfNeeded()
                VaultEncryptionManager.startIfNeeded()
                ProcessingQueue.shared.enqueuePendingProcessing()
            } catch {
                print("Vault bootstrap failed: \(error)")
            }
        }
        .onChange(of: scenePhase) { phase in
            guard hasCompletedOnboarding else { return }
            switch phase {
            case .active:
                ProcessingQueue.shared.enqueuePendingProcessing()
            case .background:
                ProcessingQueue.shared.scheduleBackgroundProcessing()
            default:
                break
            }
        }
    }
}

struct VaultBootstrapper {
    private static let vaultFolderName = "vault"

    static func bootstrapIfNeeded() throws {
        let fileManager = FileManager.default
        let rootURL = try vaultRootURL()
        try createDirectoryIfNeeded(at: rootURL)
        let style = OrganizationPreferences().style

        for directory in vaultDirectories(style: style) {
            let directoryURL = rootURL.appendingPathComponent(directory, isDirectory: true)
            try createDirectoryIfNeeded(at: directoryURL)
        }

        let systemDirectoryURL = rootURL.appendingPathComponent("_system", isDirectory: true)
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("SYSTEM.md"),
            contents: SystemRulesStore.defaultRules
        )
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("INDEX.json"),
            contents: defaultIndexJSON
        )
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("STRUCTURE.txt"),
            contents: defaultStructureText(style: style)
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

    private static func writeFileIfNeeded(at url: URL, contents: String) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try VaultFileStore.writeText(contents, to: url)
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
