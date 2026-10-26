import SwiftUI
import CoreData

enum ChatSettingsRoute: String, Identifiable {
    case overview, processing
    var id: String { rawValue }
}

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @Environment(\.themeColors) private var theme
    @EnvironmentObject private var syncStatus: SyncStatusStore
    @Binding var mode: AppMode
    @Binding var preferredBatchId: UUID?
    @State private var expandedSources: Set<UUID> = []
    @State private var reviewMessage: ChatMessage?
    @State private var settingsRoute: ChatSettingsRoute?
    @State private var pendingPresented = false
    @State private var atBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "status != %@", ScanStatus.filed.rawValue)) private var pending: FetchedResults<ScanEntity>
    @AppStorage("advancedReviewBeforeApply") private var advancedReviewBeforeApply = false
    private let bottomAnchor = "chat-bottom"

    init(
        mode: Binding<AppMode> = .constant(.chat),
        preferredBatchId: Binding<UUID?> = .constant(nil),
        viewModel: ChatViewModel? = nil
    ) {
        _mode = mode
        _preferredBatchId = preferredBatchId
        _viewModel = StateObject(wrappedValue: viewModel ?? DesignFixture.current?.chatModel() ?? ChatViewModel())
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                conversation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { inputBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { settingsRoute = .overview }.labelStyle(.iconOnly)
            }
        }
        .task { await viewModel.refreshReadiness(pendingCount: pending.count) }
        .onChange(of: pending.count) { _, _ in Task { await viewModel.refreshReadiness(pendingCount: pending.count) } }
        .sheet(item: $settingsRoute, onDismiss: { Task { await viewModel.refreshReadiness(pendingCount: pending.count) } }) { route in SettingsView(section: route == .processing ? .processing : nil) }
        .sheet(isPresented: $pendingPresented) { PendingScansView() }
        .onAppear {
            viewModel.preferredBatchId = preferredBatchId
        }
        .onChange(of: preferredBatchId) { _, newValue in
            viewModel.preferredBatchId = newValue
        }
        .sheet(item: $reviewMessage) { message in
            ApplyReviewSheet(message: message) {
                viewModel.applyFileOps(for: message)
            }
        }
    }

    private var background: some View {
        Color(uiColor: .systemBackground).ignoresSafeArea()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    readinessBanner
                    if !pending.isEmpty && viewModel.readiness == .ready {
                        Button("View pending scans (\(pending.count))") { pendingPresented = true }
                    }
                    if viewModel.messages.isEmpty && !viewModel.isThinking {
                        if viewModel.readiness == .ready { emptyState }
                    } else {
                        ForEach(viewModel.messages) { message in
                            let isApplying = viewModel.applyingMessageIds.contains(message.id)
                            let isApplied = viewModel.appliedMessageIds.contains(message.id)
                            MessageRow(
                                message: message,
                                isSourcesExpanded: sourcesBinding(for: message),
                                reviewEnabled: advancedReviewBeforeApply || viewModel.mustReviewMessageIds.contains(message.id),
                                onApply: (message.fileOps.isEmpty || viewModel.conflictingMessageIds.contains(message.id)) ? nil : { handleApply(for: message) },
                                isApplying: isApplying,
                                isApplied: isApplied
                            )
                            if viewModel.conflictingMessageIds.contains(message.id) {
                                Button("Refresh and review") { viewModel.refreshProposal(for: message) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        if viewModel.lastFailedQuery != nil {
                            Button("Try Again") { viewModel.retryResponse() }.buttonStyle(.bordered)
                        }

                        if viewModel.isThinking {
                            TypingIndicatorRow()
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                if atBottom || viewModel.messages.last?.role == .user { scrollToBottom(proxy) }
            }
            .onChange(of: viewModel.isThinking) { _, _ in
                if atBottom { scrollToBottom(proxy) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Ask about your notes")
                .font(AppTypography.title)
            Text("Ask a question about completed notes in your Library.")
                .font(AppTypography.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask about your notes", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...6)
                .accessibilityIdentifier("chatComposer")
                .padding(12)
                .font(.body)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .submitLabel(.send)
                .onSubmit { viewModel.send() }
            Button(action: viewModel.send) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(viewModel.canSend ? theme.accent : Color.secondary.opacity(0.3), in: Circle())
                    .foregroundStyle(theme.scheme == .dark ? .black : .white)
            }
            .accessibilityLabel("Send message")
            .disabled(!viewModel.canSend)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var readinessBanner: some View {
        if viewModel.readiness != .ready && viewModel.readiness != .checking {
            VStack(alignment: .leading, spacing: 8) {
                Label(viewModel.readiness.title, systemImage: "info.circle").font(.headline)
                Text(viewModel.readiness.detail).font(.callout).foregroundStyle(.secondary)
                switch viewModel.readiness {
                case .noNotes: Button("Scan a page") { mode = .capture }
                case .pending: Button("View pending scans") { pendingPresented = true }
                case .setup: Button("Set up Gemini") { settingsRoute = .processing }
                case .secureStorage: Button("Open Settings") { settingsRoute = .processing }
                case .indexUnavailable: Button("Try Again") { Task { await viewModel.refreshReadiness(pendingCount: pending.count) } }
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func sourcesBinding(for message: ChatMessage) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(message.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedSources.insert(message.id)
                } else {
                    expandedSources.remove(message.id)
                }
            }
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) } }
    }

    private func handleApply(for message: ChatMessage) {
        if advancedReviewBeforeApply || viewModel.mustReviewMessageIds.contains(message.id) {
            reviewMessage = message
        } else {
            viewModel.applyFileOps(for: message)
        }
    }
}

enum ChatMessageRole {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatMessageRole
    let text: String
    let grounded: Bool
    let sources: [ContextSource]
    let fileOps: [VaultFileOperation]
    let warnings: [String]

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        grounded: Bool = true,
        sources: [ContextSource] = [],
        fileOps: [VaultFileOperation] = [],
        warnings: [String] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.grounded = grounded
        self.sources = sources
        self.fileOps = fileOps
        self.warnings = warnings
    }
}

enum ChatReadiness: Equatable {
    case checking, ready, noNotes, pending, setup, secureStorage, indexUnavailable
    var title: String {
        switch self {
        case .noNotes: return "Start with a page"
        case .pending: return "Your pages are still processing"
        case .setup: return "Set up Gemini to chat"
        case .secureStorage: return "Secure key storage needs attention"
        case .indexUnavailable: return "Search needs attention"
        default: return "Ready to chat"
        }
    }
    var detail: String {
        switch self {
        case .noNotes: return "Capture or import pages to build your local Library."
        case .pending: return "You can ask about completed notes once they are available. Check pending scans for paused or failed processing."
        case .setup: return "Add an API key in Processing settings. Your draft stays here. Chat sends your question and selected note text to Gemini."
        case .secureStorage: return "The API key could not be read securely. Open Settings to check your setup. Your draft is preserved."
        case .indexUnavailable: return "Your notes are preserved. Try recovering local search before asking again."
        default: return ""
        }
    }
}

final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var isThinking = false
    @Published var applyingMessageIds: Set<UUID> = []
    @Published var appliedMessageIds: Set<UUID> = []

    @Published var readiness: ChatReadiness = .checking
    @Published var lastFailedQuery: String?
    @Published var conflictingMessageIds: Set<UUID> = []
    @Published var mustReviewMessageIds: Set<UUID> = []
    var fixtureResponse: ((String) async throws -> ChatResponse)?
    var applyOperations: (([VaultFileOperation], String) async throws -> VaultApplySummary)?
    private var agent: ChatAgent?
    private var reviewNextResponse = false
    var preferredBatchId: UUID?

    init(agent: ChatAgent? = nil) {
        self.agent = agent
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        guard readiness == .ready else { return }
        lastFailedQuery = nil
        draft = ""
        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true
        let batchId = preferredBatchId

        Task { [weak self] in
            guard let self else { return }
            let response = await self.respond(to: trimmed, preferredBatchId: batchId)
            await MainActor.run {
                self.messages.append(response)
                if self.reviewNextResponse && !response.fileOps.isEmpty { self.mustReviewMessageIds.insert(response.id) }
                self.reviewNextResponse = false
                self.isThinking = false
            }
        }
    }

    private func respond(to query: String, preferredBatchId: UUID?) async -> ChatMessage {
        do {
            let response: ChatResponse
            if let fixtureResponse { response = try await fixtureResponse(query) }
            else { response = try await ensureAgent().respond(to: query, preferredBatchId: preferredBatchId) }
            return ChatMessage(
                role: .assistant,
                text: response.answer,
                grounded: response.grounded,
                sources: response.usedSources,
                fileOps: response.fileOps,
                warnings: response.warnings
            )
        } catch let error as GeminiClientError {
            await MainActor.run { self.lastFailedQuery = query }
            return ChatMessage(role: .assistant, text: chatErrorMessage(error), grounded: false)
        } catch let error as ChatAgentError {
            await MainActor.run { self.lastFailedQuery = query }
            return ChatMessage(role: .assistant, text: error.localizedDescription, grounded: false)
        } catch {
            await MainActor.run { self.lastFailedQuery = query }
            return ChatMessage(
                role: .assistant,
                text: "Something went wrong. Please try again.",
                grounded: false
            )
        }
    }

    func applyFileOps(for message: ChatMessage) {
        guard !message.fileOps.isEmpty else { return }
        guard !applyingMessageIds.contains(message.id), !appliedMessageIds.contains(message.id), !conflictingMessageIds.contains(message.id) else { return }
        applyingMessageIds.insert(message.id)
        let messageId = message.id
        let fileOps = message.fileOps

        Task { [weak self] in
            guard let self else { return }
            do {
                let summary: VaultApplySummary
                if let applyOperations { summary = try await applyOperations(fileOps, "chat:\(messageId.uuidString)") }
                else { summary = try await VaultApplyService.apply(fileOps, operationID: "chat:\(messageId.uuidString)") }
                let successMessage = applySummaryMessage(summary)
                await MainActor.run {
                    self.applyingMessageIds.remove(messageId)
                    self.appliedMessageIds.insert(messageId)
                    self.messages.append(ChatMessage(role: .assistant, text: successMessage, grounded: true))
                }
                if self.applyOperations == nil { await SyncCoordinator.shared.syncIfNeeded(trigger: .applyToVault) }
            } catch {
                await MainActor.run {
                    self.applyingMessageIds.remove(messageId)
                    if let storageError = error as? VaultRepositoryError, case .staleRevision = storageError { self.conflictingMessageIds.insert(messageId) }
                    self.messages.append(
                        ChatMessage(
                            role: .assistant,
                            text: "Apply to vault failed. \(error.localizedDescription)",
                            grounded: false
                        )
                    )
                }
            }
        }
    }

    @MainActor
    func refreshReadiness(pendingCount: Int) async {
        if DesignFixture.current != nil { return }
        if !isThinking { agent = nil }
        let setup = await Task.detached { GeminiSetupStatus.inspect() }.value
        do {
            let notes = try await LibraryStore.makeDefault().notes(query: "", limit: 1)
            if notes.isEmpty { readiness = pendingCount > 0 ? .pending : .noNotes }
            else {
                switch setup {
                case .ready: readiness = .ready
                case .missingKey: readiness = .setup
                case .secureStorageUnavailable: readiness = .secureStorage
                }
            }
        } catch { readiness = .indexUnavailable }
    }

    func retryResponse() {
        guard let query = lastFailedQuery else { return }
        draft = query
        send()
    }

    func refreshProposal(for message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
              let query = messages[..<index].last(where: { $0.role == .user })?.text else { return }
        reviewNextResponse = true
        draft = query
        send()
    }

    private func applySummaryMessage(_ summary: VaultApplySummary) -> String {
        let created = summary.createdOrUpdated.count
        let deleted = summary.deleted.count
        let total = created + deleted
        if deleted == 0 {
            return "Applied \(created) change\(created == 1 ? "" : "s") to your vault."
        }
        if created == 0 {
            return "Applied \(deleted) deletion\(deleted == 1 ? "" : "s") to your vault."
        }
        return "Applied \(total) changes to your vault."
    }

    private func ensureAgent() throws -> ChatAgent {
        if let agent {
            return agent
        }
        let created = try ChatAgent.makeDefault()
        agent = created
        return created
    }

    private func chatErrorMessage(_ error: GeminiClientError) -> String {
        switch error {
        case .missingAPIKey:
            return "Chat isn't configured yet. Add a Gemini API key in Settings to continue."
        case .keychainSaveFailed:
            return "Chat couldn't store your API key securely. Open Settings and re-save your key."
        case .requestFailed(_, let message):
            if let message {
                return "Chat request failed. \(message)"
            }
            return "Chat request failed."
        default:
            return error.localizedDescription
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    @Environment(\.themeColors) private var theme
    @Binding var isSourcesExpanded: Bool
    let reviewEnabled: Bool
    let onApply: (() -> Void)?
    let isApplying: Bool
    let isApplied: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 8) {
                    bubble
                    if !message.sources.isEmpty {
                        SourcesDisclosure(sources: message.sources, isExpanded: $isSourcesExpanded)
                            .frame(maxWidth: 340, alignment: .leading)
                    }
                    if let onApply, !message.fileOps.isEmpty {
                        ApplyToVaultCard(
                            fileCount: message.fileOps.count,
                            reviewEnabled: reviewEnabled,
                            isApplying: isApplying,
                            isApplied: isApplied,
                            action: onApply
                        )
                        .frame(maxWidth: 340, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .font(AppTypography.body)
            .foregroundColor(message.role == .user ? (theme.scheme == .dark ? .black : .white) : theme.ink)
            .textSelection(.enabled)
            .padding(12)
            .background(bubbleBackground)
            .overlay(bubbleBorder)
            .frame(maxWidth: 340, alignment: message.role == .user ? .trailing : .leading)
    }

    private var bubbleBackground: some View {
        let bubbleStyle = message.role == .user
            ? AnyShapeStyle(theme.accent)
            : AnyShapeStyle(theme.surfaceStrong)
        return RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(bubbleStyle)
    }

    private var bubbleBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(message.role == .assistant ? theme.glassBorder : .clear, lineWidth: 1)
    }
}

struct SourcesDisclosure: View {
    let sources: [ContextSource]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources, id: \.path) { source in
                    SourceRow(source: source)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text("Used sources")
                Text("\(sources.count)")
                    .font(AppTypography.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.5), in: Capsule())
            }
            .font(AppTypography.caption)
            .foregroundColor(.secondary)
        }
        .tint(.secondary)
    }
}

struct ApplyToVaultCard: View {
    let fileCount: Int
    @Environment(\.themeColors) private var theme
    let reviewEnabled: Bool
    let isApplying: Bool
    let isApplied: Bool
    let action: () -> Void

    private var fileLabel: String {
        "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    }

    private var buttonTitle: String {
        if isApplied {
            return "Applied to vault"
        }
        if isApplying {
            return "Applying..."
        }
        if reviewEnabled {
            return "Review changes"
        }
        return "Apply to vault"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proposed changes")
                .font(AppTypography.caption)
                .foregroundColor(.secondary)
            Text(fileLabel)
                .font(AppTypography.caption)
                .foregroundColor(.secondary)
            Button(action: action) {
                HStack(spacing: 8) {
                    if isApplying {
                        ProgressView()
                    }
                    Text(buttonTitle)
                        .font(AppTypography.callout)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(isApplying || isApplied)
        }
        .padding(12)
        .background(theme.surfaceStrong.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SourceRow: View {
    let source: ContextSource
    @Environment(\.themeColors) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(AppTypography.callout)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.ink)
                Text(source.path)
                    .font(AppTypography.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            NavigationLink("Open") { NoteDetailView(path: source.path) }
                .buttonStyle(.bordered)

        }
        .padding(10)
        .background(theme.surfaceStrong.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TypingIndicatorRow: View {
    @Environment(\.themeColors) private var theme

    var body: some View {
        HStack {
            TypingIndicator()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.surfaceStrong.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer()
        }
        .accessibilityLabel("Assistant typing")
    }
}

struct TypingIndicator: View {
    var body: some View { ProgressView("Thinking…") }
}

@MainActor
extension ChatViewModel {
    static var preview: ChatViewModel {
        let model = ChatViewModel(agent: nil)
        model.messages = [
            ChatMessage(
                role: .user,
                text: "What did I write yesterday?"
            ),
            ChatMessage(
                role: .assistant,
                text: "You captured meeting notes about the Atlas kickoff and next steps.",
                grounded: true,
                sources: [
                    ContextSource(path: "01_daily/2026-01-20.md", title: "Daily Note - 2026-01-20"),
                    ContextSource(path: "10_projects/Project-Atlas.md", title: "Project Atlas")
                ]
            )
        ]
        return model
    }
}

#Preview {
    ChatView(mode: .constant(.chat), viewModel: .preview)
        .environmentObject(SyncStatusStore.shared)
}
