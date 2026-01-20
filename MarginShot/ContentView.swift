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
    @State private var syncState: SyncState = .idle

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                VStack(spacing: 0) {
                    HeaderView(mode: selectedMode, syncState: syncState)
                    TabView(selection: $selectedMode) {
                        CaptureView()
                            .tag(AppMode.capture)
                        ChatView()
                            .tag(AppMode.chat)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .animation(.easeInOut(duration: 0.2), value: selectedMode)
            } else {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            }
        }
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding else { return }
            do {
                try VaultBootstrapper.bootstrapIfNeeded()
            } catch {
                print("Vault bootstrap failed: \(error)")
            }
        }
    }
}

struct VaultBootstrapper {
    private static let vaultFolderName = "vault"
    private static let vaultDirectories = [
        "00_inbox",
        "01_daily",
        "10_projects",
        "11_meetings",
        "13_tasks",
        "20_learning",
        "_topics",
        "_system",
        "scans"
    ]

    static func bootstrapIfNeeded() throws {
        let fileManager = FileManager.default
        let rootURL = try vaultRootURL()
        try createDirectoryIfNeeded(at: rootURL)

        for directory in vaultDirectories {
            let directoryURL = rootURL.appendingPathComponent(directory, isDirectory: true)
            try createDirectoryIfNeeded(at: directoryURL)
        }

        let systemDirectoryURL = rootURL.appendingPathComponent("_system", isDirectory: true)
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("SYSTEM.md"),
            contents: defaultSystemRules
        )
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("INDEX.json"),
            contents: defaultIndexJSON
        )
        try writeFileIfNeeded(
            at: systemDirectoryURL.appendingPathComponent("STRUCTURE.txt"),
            contents: defaultStructureText
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
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let defaultSystemRules = """
    # System Rules

    - Depth over breadth; prioritize clean, composable notes.
    - Prefer claim-style headings when confident.
    - Weave wiki-links inline when referencing concepts or projects.
    - Don't invent facts; mark uncertain items as TODO.
    - Keep a raw transcription section for traceability.
    """

    private static let defaultIndexJSON = """
    {
      "notes": []
    }
    """

    private static let defaultStructureText = """
    vault/
    00_inbox/
    01_daily/
    10_projects/
    11_meetings/
    13_tasks/
    20_learning/
    _topics/
    _system/
    scans/
    """
}

enum VaultBootstrapError: Error {
    case documentsDirectoryUnavailable
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
