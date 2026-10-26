import SwiftUI

enum SyncState: String {
    case off
    case idle
    case waiting
    case syncing
    case error

    var iconName: String {
        switch self {
        case .off:
            return "minus.circle"
        case .waiting:
            return "clock"
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
            return "Backup off"
        case .waiting:
            return "Backup pending"
        case .idle:
            return "Backed up"
        case .syncing:
            return "Backing up"
        case .error:
            return "Backup needs attention"
        }
    }

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .waiting:
            return "Pending"
        case .idle:
            return "Backed up"
        case .syncing:
            return "Backing up"
        case .error:
            return "Issue"
        }
    }

    var tint: Color {
        switch self {
        case .off:
            return .secondary
        case .idle, .waiting:
            return .secondary
        case .syncing:
            return .blue
        case .error:
            return .orange
        }
    }
}

struct SyncStatusView: View {
    let state: SyncState
    var body: some View {
        Label(state.accessibilityLabel, systemImage: state.iconName)
            .font(.callout)
            .foregroundStyle(state.tint)
    }
}
