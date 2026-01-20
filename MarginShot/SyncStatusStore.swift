import Combine
import Foundation

@MainActor
final class SyncStatusStore: ObservableObject {
    static let shared = SyncStatusStore()

    @Published private(set) var state: SyncState = .off
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastErrorAt: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var destination: SyncDestination = .off

    private init() {
        refreshDestination()
    }

    func refreshDestination() {
        let raw = UserDefaults.standard.string(forKey: SyncDefaults.destinationKey) ?? SyncDestination.off.rawValue
        let resolved = SyncDestination(rawValue: raw) ?? .off
        updateDestination(resolved)
    }

    func updateDestination(_ destination: SyncDestination) {
        self.destination = destination
        if destination == .off {
            state = .off
            clearError()
        } else if state == .off {
            state = .idle
        }
    }

    func markSyncing() {
        guard destination != .off else {
            state = .off
            return
        }
        state = .syncing
    }

    func markIdle(at date: Date = Date()) {
        guard destination != .off else {
            state = .off
            return
        }
        state = .idle
        lastSyncAt = date
        clearError()
    }

    func markIdleSkippingSync() {
        guard destination != .off else {
            state = .off
            return
        }
        state = .idle
        lastErrorMessage = nil
        lastErrorAt = nil
    }

    func markError(_ message: String, at date: Date = Date()) {
        guard destination != .off else {
            state = .off
            return
        }
        state = .error
        lastErrorMessage = message
        lastErrorAt = date
    }

    func clearError() {
        lastErrorMessage = nil
        lastErrorAt = nil
        if destination != .off, state == .error {
            state = .idle
        }
    }
}
