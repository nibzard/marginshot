import SwiftUI

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

    @AppStorage("processingAutoProcessInbox") private var autoProcessInbox = true
    @AppStorage("processingQualityMode") private var processingQualityModeRaw = ProcessingQualityMode.balanced.rawValue
    @AppStorage("processingWiFiOnly") private var processingWiFiOnly = false
    @AppStorage("processingRequiresCharging") private var processingRequiresCharging = false

    @AppStorage("syncDestination") private var syncDestinationRaw = SyncDestination.off.rawValue
    @AppStorage("syncWiFiOnly") private var syncWiFiOnly = false
    @AppStorage("syncRequiresCharging") private var syncRequiresCharging = false

    @AppStorage("organizationStyle") private var organizationStyleRaw = OrganizationStyle.simple.rawValue
    @AppStorage("organizationLinkingEnabled") private var organizationLinkingEnabled = true
    @AppStorage("organizationTaskExtractionEnabled") private var organizationTaskExtractionEnabled = false
    @AppStorage("organizationTopicPagesEnabled") private var organizationTopicPagesEnabled = false

    @AppStorage("privacySendImagesToLLM") private var privacySendImagesToLLM = true
    @AppStorage("privacyLocalEncryptionEnabled") private var privacyLocalEncryptionEnabled = false

    @AppStorage("advancedReviewBeforeApply") private var advancedReviewBeforeApply = false
    @AppStorage("advancedEnableZipExport") private var advancedEnableZipExport = false

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
                    Toggle("Local encryption", isOn: $privacyLocalEncryptionEnabled)
                } footer: {
                    Text("Turning off image uploads reduces transcription quality.")
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
    }
}

#Preview {
    SettingsView()
}
