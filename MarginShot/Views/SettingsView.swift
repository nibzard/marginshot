import SwiftUI
import UniformTypeIdentifiers
import AuthenticationServices
import CryptoKit
import Security
import UIKit

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

enum GitHubDefaults {
    static let userLoginKey = "githubUserLogin"
    static let repoOwnerKey = "githubRepoOwner"
    static let repoNameKey = "githubRepoName"
    static let repoFullNameKey = "githubRepoFullName"
    static let repoBranchKey = "githubRepoDefaultBranch"
    static let lastSyncAtLegacyKey = "githubLastSyncAt"

    static func lastSyncAtKey(owner: String, name: String, branch: String) -> String {
        let normalizedBranch = branch.isEmpty ? "main" : branch
        return "githubLastSyncAt.\(owner)/\(name)#\(normalizedBranch)"
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
    @StateObject private var performanceStore = PerformanceMetricsStore.shared

    @AppStorage("processingAutoProcessInbox") private var autoProcessInbox = true
    @AppStorage("processingQualityMode") private var processingQualityModeRaw = ProcessingQualityMode.balanced.rawValue
    @AppStorage("processingWiFiOnly") private var processingWiFiOnly = false
    @AppStorage("processingRequiresCharging") private var processingRequiresCharging = false

    @AppStorage(SyncDefaults.destinationKey) private var syncDestinationRaw = SyncDestination.off.rawValue
    @AppStorage(SyncDefaults.wiFiOnlyKey) private var syncWiFiOnly = false
    @AppStorage(SyncDefaults.requiresChargingKey) private var syncRequiresCharging = false
    @AppStorage(SyncDefaults.folderBookmarkKey) private var syncFolderBookmark = Data()
    @AppStorage(SyncDefaults.folderDisplayNameKey) private var syncFolderDisplayName = ""
    @AppStorage(GitHubDefaults.userLoginKey) private var gitHubUserLogin = ""
    @AppStorage(GitHubDefaults.repoOwnerKey) private var gitHubRepoOwner = ""
    @AppStorage(GitHubDefaults.repoNameKey) private var gitHubRepoName = ""
    @AppStorage(GitHubDefaults.repoFullNameKey) private var gitHubRepoFullName = ""
    @AppStorage(GitHubDefaults.repoBranchKey) private var gitHubRepoBranch = ""

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
    @State private var hasGitHubToken = false
    @State private var isSigningInToGitHub = false
    @State private var gitHubAuthStatus: String?
    @State private var isPickingGitHubRepo = false
    @State private var isExportingVaultZip = false
    @State private var isShowingZipShare = false
    @State private var vaultZipURL: URL?
    @State private var vaultZipError: String?
    @State private var isShowingEncryptionDisabledNotice = false

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

    private var hasSelectedGitHubRepo: Bool {
        !gitHubRepoOwner.isEmpty && !gitHubRepoName.isEmpty
    }

    private var gitHubRepoDisplayName: String {
        guard hasSelectedGitHubRepo else {
            return "No repository selected"
        }
        let fullName = gitHubRepoFullName.isEmpty
            ? "\(gitHubRepoOwner)/\(gitHubRepoName)"
            : gitHubRepoFullName
        if gitHubRepoBranch.isEmpty {
            return "Repository: \(fullName)"
        }
        return "Repository: \(fullName) (\(gitHubRepoBranch))"
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
                    Text("Control background processing and model depth. Raw transcripts are stored in each note under \"Raw transcription\".")
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
                    if syncDestination.wrappedValue == .github {
                        VStack(alignment: .leading, spacing: 8) {
                            if hasGitHubToken {
                                Text(gitHubUserLogin.isEmpty ? "GitHub connected" : "Signed in as \(gitHubUserLogin)")
                                    .font(.subheadline)
                                Text(gitHubRepoDisplayName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button("Choose Repository") {
                                        isPickingGitHubRepo = true
                                    }
                                    .buttonStyle(.bordered)
                                    if hasSelectedGitHubRepo {
                                        Button("Clear Repository") {
                                            clearGitHubRepoSelection()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                Button("Sign out") {
                                    signOutGitHub()
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button(isSigningInToGitHub ? "Connecting..." : "Connect GitHub") {
                                    signInGitHub()
                                }
                                .buttonStyle(.bordered)
                                .disabled(isSigningInToGitHub)
                                if let gitHubAuthStatus {
                                    Text(gitHubAuthStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Sign in to choose a repository for sync.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Sync stays off until you choose a destination. Runs after processing and apply-to-vault.")
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
                    NavigationLink("Edit System Rules") {
                        SystemRulesEditorView()
                    }
                } footer: {
                    Text("Tune how notes are structured and connected. Manage notebooks and overrides from Capture.")
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

                Section("Performance") {
                    ForEach(PerformanceMetric.primaryMetrics) { metric in
                        PerformanceMetricRow(
                            metric: metric,
                            valueText: performanceStore.formattedValue(for: metric),
                            targetText: performanceStore.formattedTarget(for: metric),
                            status: performanceStore.status(for: metric)
                        )
                    }
                    Button("Reset metrics") {
                        performanceStore.reset()
                    }
                } footer: {
                    Text("Targets align with the performance budgets in SPECS.")
                }

                Section("Advanced") {
                    Toggle("Review changes before applying", isOn: $advancedReviewBeforeApply)
                    Toggle("Enable ZIP export", isOn: $advancedEnableZipExport)
                    if advancedEnableZipExport {
                        Button(isExportingVaultZip ? "Preparing ZIP..." : "Export vault as ZIP") {
                            exportVaultZip()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExportingVaultZip)
                        if let vaultZipError {
                            Text(vaultZipError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
            refreshGitHubStatus()
        }
        .onChange(of: syncDestinationRaw) { newValue in
            let resolved = SyncDestination(rawValue: newValue) ?? .off
            syncStatus.updateDestination(resolved)
            if resolved == .folder, syncFolderDisplayName.isEmpty {
                syncStatus.markError("Select a folder in Settings to enable sync.")
            }
            if resolved == .github {
                let hasToken = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) != nil
                hasGitHubToken = hasToken
                if !hasToken {
                    syncStatus.markError("Connect GitHub in Settings to enable sync.")
                } else if !hasSelectedGitHubRepo {
                    syncStatus.markError("Select a GitHub repository in Settings to enable sync.")
                }
            }
        }
        .onChange(of: autoProcessInbox) { newValue in
            if newValue {
                ProcessingQueue.shared.enqueuePendingProcessing()
            }
        }
        .onChange(of: privacySendImagesToLLM) { newValue in
            if newValue {
                ProcessingQueue.shared.enqueuePendingProcessing()
            }
        }
        .onChange(of: privacyLocalEncryptionEnabled) { newValue in
            VaultEncryptionManager.handleSettingChange(enabled: newValue)
            if !newValue {
                isShowingEncryptionDisabledNotice = true
            }
        }
        .onChange(of: advancedEnableZipExport) { newValue in
            if !newValue {
                clearVaultZipState()
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
        .sheet(isPresented: $isPickingGitHubRepo) {
            if let token = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) {
                GitHubRepoPickerView(token: token) { repo in
                    gitHubRepoOwner = repo.owner.login
                    gitHubRepoName = repo.name
                    gitHubRepoFullName = repo.fullName
                    gitHubRepoBranch = repo.defaultBranch
                    updateGitHubSyncErrorIfNeeded()
                }
            } else {
                Text("Sign in to GitHub to select a repository.")
                    .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $isShowingZipShare, onDismiss: {
            cleanupVaultZip()
        }) {
            if let vaultZipURL {
                ActivityView(activityItems: [vaultZipURL])
            } else {
                Text("No ZIP available.")
                    .presentationDetents([.medium])
            }
        }
        .alert("Local encryption is off", isPresented: $isShowingEncryptionDisabledNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Existing encrypted files remain encrypted until rewritten. Full-text search will rebuild now.")
        }
    }

    private var canSaveGeminiAPIKey: Bool {
        !geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshGeminiAPIKeyStatus() {
        hasGeminiAPIKey = KeychainStore.readString(forKey: KeychainStore.geminiAPIKeyKey) != nil
        geminiAPIKeyStatus = nil
    }

    private func exportVaultZip() {
        isExportingVaultZip = true
        vaultZipError = nil
        Task {
            do {
                let zipURL = try createVaultZip()
                await MainActor.run {
                    vaultZipURL = zipURL
                    isShowingZipShare = true
                    isExportingVaultZip = false
                }
            } catch {
                await MainActor.run {
                    vaultZipError = error.localizedDescription
                    isExportingVaultZip = false
                }
            }
        }
    }

    private func createVaultZip() throws -> URL {
        let vaultURL = try vaultRootURL()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VaultZipExportError.vaultUnavailable
        }
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(zipFileName(), isDirectory: false)
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try FileManager.default.zipItem(at: vaultURL, to: zipURL, shouldKeepParent: true)
        return zipURL
    }

    private func zipFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return "marginshot-vault-\(timestamp).zip"
    }

    private func vaultRootURL() throws -> URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultZipExportError.vaultUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    private func clearVaultZipState() {
        vaultZipError = nil
        cleanupVaultZip()
    }

    private func cleanupVaultZip() {
        if let vaultZipURL {
            try? FileManager.default.removeItem(at: vaultZipURL)
        }
        vaultZipURL = nil
        isShowingZipShare = false
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

    private func refreshGitHubStatus() {
        let hasToken = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) != nil
        hasGitHubToken = hasToken
        guard hasToken, gitHubUserLogin.isEmpty else { return }
        Task {
            await loadGitHubUser()
        }
    }

    private func signInGitHub() {
        isSigningInToGitHub = true
        gitHubAuthStatus = nil
        Task {
            do {
                let token = try await GitHubOAuthSession.authorize()
                try KeychainStore.saveString(token, forKey: KeychainStore.githubAccessTokenKey)
                let user = try await GitHubAPI.fetchUser(token: token)
                await MainActor.run {
                    hasGitHubToken = true
                    gitHubUserLogin = user.login
                    gitHubAuthStatus = "GitHub connected."
                    updateGitHubSyncErrorIfNeeded()
                }
            } catch {
                await MainActor.run {
                    gitHubAuthStatus = error.localizedDescription
                }
            }
            await MainActor.run {
                isSigningInToGitHub = false
            }
        }
    }

    private func signOutGitHub() {
        do {
            try KeychainStore.delete(forKey: KeychainStore.githubAccessTokenKey)
            gitHubAuthStatus = nil
        } catch {
            gitHubAuthStatus = "Failed to sign out of GitHub."
        }
        hasGitHubToken = false
        gitHubUserLogin = ""
        clearGitHubRepoSelection()
        updateGitHubSyncErrorIfNeeded()
    }

    private func clearGitHubRepoSelection() {
        let defaults = UserDefaults.standard
        if !gitHubRepoOwner.isEmpty, !gitHubRepoName.isEmpty {
            let lastSyncKey = GitHubDefaults.lastSyncAtKey(
                owner: gitHubRepoOwner,
                name: gitHubRepoName,
                branch: gitHubRepoBranch
            )
            defaults.removeObject(forKey: lastSyncKey)
        }
        defaults.removeObject(forKey: GitHubDefaults.lastSyncAtLegacyKey)
        gitHubRepoOwner = ""
        gitHubRepoName = ""
        gitHubRepoFullName = ""
        gitHubRepoBranch = ""
    }

    private func updateGitHubSyncErrorIfNeeded() {
        guard syncDestination.wrappedValue == .github else { return }
        let hasToken = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) != nil
        hasGitHubToken = hasToken
        if !hasToken {
            syncStatus.markError("Connect GitHub in Settings to enable sync.")
        } else if !hasSelectedGitHubRepo {
            syncStatus.markError("Select a GitHub repository in Settings to enable sync.")
        } else {
            syncStatus.clearError()
        }
    }

    @MainActor
    private func loadGitHubUser() async {
        guard let token = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) else { return }
        do {
            let user = try await GitHubAPI.fetchUser(token: token)
            gitHubUserLogin = user.login
        } catch {
            gitHubAuthStatus = error.localizedDescription
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

    private enum VaultZipExportError: LocalizedError {
        case vaultUnavailable

        var errorDescription: String? {
            switch self {
            case .vaultUnavailable:
                return "Vault folder not found yet."
            }
        }
    }
}

private struct PerformanceMetricRow: View {
    let metric: PerformanceMetric
    let valueText: String
    let targetText: String?
    let status: PerformanceStatus?

    private var valueColor: Color {
        switch status {
        case .outsideTarget:
            return .orange
        case .withinTarget:
            return .primary
        case .none:
            return .secondary
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.displayName)
                    .font(.subheadline)
                if let targetText {
                    Text(targetText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(valueText)
                .font(.subheadline)
                .foregroundStyle(valueColor)
        }
        .padding(.vertical, 2)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct GitHubRepoPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let token: String
    let onSelect: (GitHubRepo) -> Void

    @State private var repos: [GitHubRepo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(repos) { repo in
                    Button {
                        onSelect(repo)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repo.fullName)
                                .font(.body)
                            Text(repo.isPrivate ? "Private" : "Public")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading repositories...")
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task {
                                await loadRepos()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else if repos.isEmpty {
                    Text("No repositories found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Select Repository")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadRepos()
            }
        }
    }

    @MainActor
    private func loadRepos() async {
        isLoading = true
        errorMessage = nil
        do {
            repos = try await GitHubAPI.fetchRepos(token: token)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

enum GitHubOAuthError: LocalizedError {
    case missingClientID
    case missingRedirectURI
    case invalidRedirectURI
    case authorizationCancelled
    case missingCode
    case stateMismatch
    case tokenExchangeFailed
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "GitHub client ID is missing in Info.plist."
        case .missingRedirectURI:
            return "GitHub redirect URI is missing in Info.plist."
        case .invalidRedirectURI:
            return "GitHub redirect URI is invalid."
        case .authorizationCancelled:
            return "GitHub sign-in was cancelled."
        case .missingCode:
            return "GitHub authorization did not return a code."
        case .stateMismatch:
            return "GitHub authorization state did not match."
        case .tokenExchangeFailed:
            return "GitHub token exchange failed."
        case .authFailed(let message):
            return "GitHub sign-in failed. \(message)"
        }
    }
}

struct GitHubOAuthConfiguration {
    let clientID: String
    let redirectURI: String
    let callbackScheme: String
    let scope: String

    static func load() throws -> GitHubOAuthConfiguration {
        guard let rawClientID = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String else {
            throw GitHubOAuthError.missingClientID
        }
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, clientID != "REPLACE_ME" else {
            throw GitHubOAuthError.missingClientID
        }
        guard let redirectURI = Bundle.main.object(forInfoDictionaryKey: "GitHubRedirectURI") as? String else {
            throw GitHubOAuthError.missingRedirectURI
        }
        guard let redirectURL = URL(string: redirectURI), let scheme = redirectURL.scheme else {
            throw GitHubOAuthError.invalidRedirectURI
        }
        return GitHubOAuthConfiguration(
            clientID: clientID,
            redirectURI: redirectURI,
            callbackScheme: scheme,
            scope: "repo"
        )
    }
}

@MainActor
enum GitHubOAuthSession {
    private static var activeSession: ASWebAuthenticationSession?
    private static let presentationProvider = GitHubOAuthPresentationContextProvider()

    static func authorize() async throws -> String {
        let config = try GitHubOAuthConfiguration.load()
        let codeVerifier = GitHubPKCE.codeVerifier()
        let state = GitHubPKCE.state()
        let codeChallenge = GitHubPKCE.codeChallenge(for: codeVerifier)
        let authURL = authorizationURL(
            clientID: config.clientID,
            redirectURI: config.redirectURI,
            scope: config.scope,
            state: state,
            codeChallenge: codeChallenge
        )
        let code = try await requestAuthorizationCode(
            authURL: authURL,
            callbackScheme: config.callbackScheme,
            expectedState: state
        )
        do {
            return try await GitHubAPI.exchangeCodeForToken(
                clientID: config.clientID,
                code: code,
                redirectURI: config.redirectURI,
                codeVerifier: codeVerifier
            )
        } catch {
            throw GitHubOAuthError.tokenExchangeFailed
        }
    }

    private static func authorizationURL(
        clientID: String,
        redirectURI: String,
        scope: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url ?? URL(string: "https://github.com/login/oauth/authorize")!
    }

    private static func requestAuthorizationCode(
        authURL: URL,
        callbackScheme: String,
        expectedState: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                defer { activeSession = nil }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: GitHubOAuthError.authorizationCancelled)
                    return
                }
                if let error = error {
                    continuation.resume(throwing: GitHubOAuthError.authFailed(error.localizedDescription))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GitHubOAuthError.missingCode)
                    return
                }
                guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: GitHubOAuthError.missingCode)
                    return
                }
                let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
                guard returnedState == expectedState else {
                    continuation.resume(throwing: GitHubOAuthError.stateMismatch)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = presentationProvider
            session.prefersEphemeralWebBrowserSession = true
            activeSession = session
            session.start()
        }
    }
}

final class GitHubOAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}

enum GitHubPKCE {
    static func codeVerifier() -> String {
        base64URLSafeString(from: randomBytes(length: 32))
    }

    static func state() -> String {
        base64URLSafeString(from: randomBytes(length: 16))
    }

    static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return base64URLSafeString(from: Data(hashed))
    }

    private static func randomBytes(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        return Data(UUID().uuidString.utf8)
    }

    private static func base64URLSafeString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncStatusStore.shared)
}
