import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var expandedSources: Set<UUID> = []
    private let bottomAnchor = "chat-bottom"

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                conversation
                inputBar
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(.systemGray6), Color(.systemGray5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if viewModel.messages.isEmpty && !viewModel.isThinking {
                        emptyState
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageRow(
                                message: message,
                                isSourcesExpanded: sourcesBinding(for: message)
                            )
                        }

                        if viewModel.isThinking {
                            TypingIndicatorRow()
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isThinking) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Ask about your notes")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Your captures will appear here once processed.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("Used sources stay hidden until expanded.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask about your notes", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .submitLabel(.send)
                .onSubmit {
                    viewModel.send()
                }

            Button(action: viewModel.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(
                        viewModel.canSend ? Color.accentColor : Color.gray.opacity(0.35),
                        in: Circle()
                    )
                    .foregroundColor(.white)
            }
            .disabled(!viewModel.canSend)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
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
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
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
    let warnings: [String]

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        grounded: Bool = true,
        sources: [ContextSource] = [],
        warnings: [String] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.grounded = grounded
        self.sources = sources
        self.warnings = warnings
    }
}

final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var isThinking = false

    private var agent: ChatAgent?

    init(agent: ChatAgent? = nil) {
        self.agent = agent
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        draft = ""
        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true

        Task { [weak self] in
            guard let self else { return }
            let response = await self.respond(to: trimmed)
            await MainActor.run {
                self.messages.append(response)
                self.isThinking = false
            }
        }
    }

    private func respond(to query: String) async -> ChatMessage {
        do {
            let agent = try ensureAgent()
            let response = try await agent.respond(to: query)
            return ChatMessage(
                role: .assistant,
                text: response.answer,
                grounded: response.grounded,
                sources: response.usedSources,
                warnings: response.warnings
            )
        } catch let error as GeminiClientError {
            return ChatMessage(role: .assistant, text: chatErrorMessage(error), grounded: false)
        } catch let error as ChatAgentError {
            return ChatMessage(role: .assistant, text: error.localizedDescription, grounded: false)
        } catch {
            return ChatMessage(
                role: .assistant,
                text: "Something went wrong. Please try again.",
                grounded: false
            )
        }
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
            return "Chat isn't configured yet. Add a Gemini API key to continue."
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
    @Binding var isSourcesExpanded: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 8) {
                    bubble
                    if !message.sources.isEmpty {
                        SourcesDisclosure(sources: message.sources, isExpanded: $isSourcesExpanded)
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
            .font(.body)
            .foregroundColor(message.role == .user ? .white : .primary)
            .textSelection(.enabled)
            .padding(12)
            .background(bubbleBackground)
            .overlay(bubbleBorder)
            .frame(maxWidth: 340, alignment: message.role == .user ? .trailing : .leading)
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(message.role == .user ? Color.accentColor : .ultraThinMaterial)
    }

    private var bubbleBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(message.role == .assistant ? Color.primary.opacity(0.08) : .clear, lineWidth: 1)
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
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5), in: Capsule())
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .tint(.secondary)
    }
}

struct SourceRow: View {
    let source: ContextSource
    @Environment(\.openURL) private var openURL

    private var fileURL: URL? {
        VaultLocation.fileURL(relativePath: source.path)
    }

    private var canOpen: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(source.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Open") {
                guard let fileURL else { return }
                openURL(fileURL)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canOpen)
        }
        .padding(10)
        .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TypingIndicatorRow: View {
    var body: some View {
        HStack {
            TypingIndicator()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer()
        }
        .accessibilityLabel("Assistant typing")
    }
}

struct TypingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1 : 0.5)
                    .opacity(isAnimating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }
}

private enum VaultLocation {
    static func fileURL(relativePath: String) -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsURL
            .appendingPathComponent("vault", isDirectory: true)
            .appendingPathComponent(relativePath)
    }
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
    ChatView(viewModel: .preview)
}
