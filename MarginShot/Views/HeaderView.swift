import SwiftUI

enum SyncState: String {
    case off
    case idle
    case syncing
    case error

    var iconName: String {
        switch self {
        case .off:
            return "minus.circle"
        case .idle:
            return "checkmark.circle"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .off:
            return "Sync off"
        case .idle:
            return "Sync idle"
        case .syncing:
            return "Syncing"
        case .error:
            return "Sync error"
        }
    }

    var tint: Color {
        switch self {
        case .off:
            return .secondary
        case .idle:
            return .secondary
        case .syncing:
            return .blue
        case .error:
            return .orange
        }
    }
}

struct HeaderView: View {
    let mode: AppMode
    let syncState: SyncState

    var body: some View {
        HStack(spacing: 12) {
            Text(mode.title)
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            SyncStatusView(state: syncState)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct SyncStatusView: View {
    let state: SyncState

    var body: some View {
        Label(state.accessibilityLabel, systemImage: state.iconName)
            .labelStyle(.iconOnly)
            .symbolRenderingMode(.hierarchical)
            .foregroundColor(state.tint)
    }
}

#Preview {
    HeaderView(mode: .capture, syncState: .idle)
}
