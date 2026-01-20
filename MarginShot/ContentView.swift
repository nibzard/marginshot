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
    @State private var selectedMode: AppMode = .capture
    @State private var syncState: SyncState = .idle

    var body: some View {
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
    }
}

#Preview {
    ContentView()
}
