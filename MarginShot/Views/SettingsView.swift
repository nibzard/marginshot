import SwiftUI
import UniformTypeIdentifiers

enum SyncDestination: String, CaseIterable, Identifiable {
    case off
    case folder
    case github
    case gitRemote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .folder:
            return "Folder"
        case .github:
            return "GitHub"
        case .gitRemote:
            return "Custom Git Remote"
        }
    }
}

enum SyncDefaults {
    static let destinationKey = "syncDestination"
    static let wiFiOnlyKey = "syncWiFiOnly"
    static let requiresChargingKey = "syncRequiresCharging"
    static let folderBookmarkKey = "syncFolderBookmark"
    static let folderDisplayNameKey = "syncFolderDisplayName"
}

enum OrganizationStyle: String, CaseIterable, Identifiable {
    case simple
    case johnnyDecimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple:
            return "Simple Folders"
        case .johnnyDecimal:
            return "Johnny.Decimal"
        }
    }
}

extension ProcessingQualityMode {
    var title: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .best:
            return "Best"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncStatus: SyncStatusStore

    @AppStorage("processingAutoProcessInbox") private var autoProcessInbox = true
    @AppStorage("processingQualityMode") private var processingQualityModeRaw = ProcessingQualityMode.balanced.rawValue
    @AppStorage("processingWiFiOnly") private var processingWiFiOnly = false
    @AppStorage("processingRequiresCharging") private var processingRequiresCharging = false

    @AppStorage(SyncDefaults.destinationKey) private var syncDestinationRaw = SyncDestination.off.rawValue
    @AppStorage(SyncDefaults.wiFiOnlyKey) private var syncWiFiOnly = false
    @AppStorage(SyncDefaults.requiresChargingKey) private var syncRequiresCharging = false
    @AppStorage(SyncDefaults.folderBookmarkKey) private var syncFolderBookmark = Data()
    @AppStorage(SyncDefaults.folderDisplayNameKey) private var syncFolderDisplayName = ""

    @AppStorage("organizationStyle") private var organizationStyleRaw = OrganizationStyle.simple.rawValue
    @AppStorage("organizationLinkingEnabled") private var organizationLinkingEnabled = true
    @AppStorage("organizationTaskExtractionEnabled") private var organizationTaskExtractionEnabled = false
    @AppStorage("organizationTopicPagesEnabled") private var organizationTopicPagesEnabled = false

    @AppStorage("privacySendImagesToLLM") private var privacySendImagesToLLM = true
    @AppStorage("privacyLocalEncryptionEnabled") private var privacyLocalEncryptionEnabled = false

    @AppStorage("advancedReviewBeforeApply") private var advancedReviewBeforeApply = false
    @AppStorage("advancedEnableZipExport") private var advancedEnableZipExport = false

    @State private var geminiAPIKeyDraft = ""
    @State private var hasGeminiAPIKey = false
    @State private var geminiAPIKeyStatus: String?
    @State private var isPickingSyncFolder = false

    private var syncDestination: Binding<SyncDestination> {
        Binding(
            get: { SyncDestination(rawValue: syncDestinationRaw) ?? .off },
            set: { syncDestinationRaw = $0.rawValue }
        )
    }

    private var organizationStyle: Binding<OrganizationStyle> {
        Binding(
            get: { OrganizationStyle(rawValue: organizationStyleRaw) ?? .simple },
            set: { organizationStyleRaw = $0.rawValue }
        )
    }

    private var processingQualityMode: Binding<ProcessingQualityMode> {
        Binding(
            get: { ProcessingQualityMode(rawValue: processingQualityModeRaw) ?? .balanced },
            set: { processingQualityModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                syncStatusBanner

                Section("Processing") {
                    Toggle("Auto-process inbox", isOn: $autoProcessInbox)
                    Picker("Quality mode", selection: processingQualityMode) {
                        ForEach(ProcessingQualityMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Wi-Fi only", isOn: $processingWiFiOnly)
                    Toggle("Charging only", isOn: $processingRequiresCharging)
                } footer: {
                    Text("Control background processing and model depth.")
                }

                Section("Sync") {
                    Picker("Destination", selection: syncDestination) {
                        ForEach(SyncDestination.allCases) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    Toggle("Wi-Fi only", isOn: $syncWiFiOnly)
                    Toggle("Charging only", isOn: $syncRequiresCharging)
                    if syncDestination.wrappedValue == .folder {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(syncFolderDisplayName.isEmpty ? "No folder selected" : syncFolderDisplayName)
                                .foregroundStyle(syncFolderDisplayName.isEmpty ? .secondary : .primary)
                            Button("Choose Folder") {
                                isPickingSyncFolder = true
                            }
                            if !syncFolderDisplayName.isEmpty {
                                Button("Clear Folder") {
                                    syncFolderBookmark = Data()
                                    syncFolderDisplayName = ""
                                    syncStatus.markError("Select a folder in Settings to enable sync.")
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Sync runs after processing and apply-to-vault.")
                }

                Section("Organization") {
                    Picker("Folder style", selection: organizationStyle) {
                        ForEach(OrganizationStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Toggle("Linking", isOn: $organizationLinkingEnabled)
                    Toggle("Task extraction", isOn: $organizationTaskExtractionEnabled)
                    Toggle("Topic pages", isOn: $organizationTopicPagesEnabled)
                } footer: {
                    Text("Tune how notes are structured and connected.")
                }

                Section("Privacy") {
                    Toggle("Send images to LLM", isOn: $privacySendImagesToLLM)
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Gemini API key", text: $geminiAPIKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        HStack(spacing: 12) {
                            Button("Save API key") {
                                saveGeminiAPIKey()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canSaveGeminiAPIKey)
                            if hasGeminiAPIKey {
                                Button("Clear") {
                                    clearGeminiAPIKey()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if let geminiAPIKeyStatus {
                            Text(geminiAPIKeyStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if hasGeminiAPIKey {
                            Text("API key stored in Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Local encryption", isOn: $privacyLocalEncryptionEnabled)
                } footer: {
                    Text("When enabled, page images are sent to the LLM provider for transcription. Turn this off to keep images on device; scans stay in the inbox until re-enabled.")
                }

                Section("Advanced") {
                    Toggle("Review changes before applying", isOn: $advancedReviewBeforeApply)
                    Toggle("Enable ZIP export", isOn: $advancedEnableZipExport)
                } footer: {
                    Text("Extra controls for power users.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            syncStatus.refreshDestination()
            refreshGeminiAPIKeyStatus()
        }
        .onChange(of: syncDestinationRaw) { newValue in
            let resolved = SyncDestination(rawValue: newValue) ?? .off
            syncStatus.updateDestination(resolved)
            if resolved == .folder, syncFolderDisplayName.isEmpty {
                syncStatus.markError("Select a folder in Settings to enable sync.")
            }
        }
        .onChange(of: privacySendImagesToLLM) { newValue in
            if newValue {
                ProcessingQueue.shared.enqueuePendingProcessing()
            }
        }
        .fileImporter(
            isPresented: $isPickingSyncFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let bookmark = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    syncFolderBookmark = bookmark
                    syncFolderDisplayName = url.lastPathComponent
                    syncStatus.clearError()
                } catch {
                    print("Failed to store sync folder bookmark: \(error)")
                }
            case .failure(let error):
                print("Sync folder selection failed: \(error)")
            }
        }
    }

    private var canSaveGeminiAPIKey: Bool {
        !geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshGeminiAPIKeyStatus() {
        hasGeminiAPIKey = KeychainStore.readString(forKey: KeychainStore.geminiAPIKeyKey) != nil
        geminiAPIKeyStatus = nil
    }

    private func saveGeminiAPIKey() {
        let trimmed = geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore.saveString(trimmed, forKey: KeychainStore.geminiAPIKeyKey)
            geminiAPIKeyDraft = ""
            hasGeminiAPIKey = true
            geminiAPIKeyStatus = "API key saved."
        } catch {
            geminiAPIKeyStatus = "Failed to save API key."
        }
    }

    private func clearGeminiAPIKey() {
        do {
            try KeychainStore.delete(forKey: KeychainStore.geminiAPIKeyKey)
            hasGeminiAPIKey = false
            geminiAPIKeyStatus = "API key removed."
        } catch {
            geminiAPIKeyStatus = "Failed to remove API key."
        }
    }

    @ViewBuilder
    private var syncStatusBanner: some View {
        if syncStatus.state == .error {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Sync needs attention")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    Text(syncStatus.lastErrorMessage ?? "Sync failed. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry now") {
                        Task {
                            await SyncCoordinator.shared.syncIfNeeded(trigger: .manual)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncStatusStore.shared)
}
