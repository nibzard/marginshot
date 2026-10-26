import Foundation

struct VaultSyncItem: Equatable {
    let path: String
    let revision: VaultRevision
}

struct VaultSyncSnapshot {
    let item: VaultSyncItem
    /// Immutable stored bytes. Nil represents a revisioned deletion.
    let data: Data?
}

protocol VaultSyncDestination {
    var identity: String { get }
    var legacyManifest: Set<String> { get }
    func send(_ snapshot: VaultSyncSnapshot) async throws
}

final class RevisionSyncEngine {
    let repository: VaultRepository
    private static let excludedPaths: Set<String> = ["_system/search.sqlite", "_system/search.sqlite-wal", "_system/search.sqlite-shm"]

    init(repository: VaultRepository) { self.repository = repository }

    func pending(destination: String, legacyManifest: Set<String> = []) throws -> [VaultSyncItem] {
        try reconcile(legacyManifest: legacyManifest)
        let state = try repository.revisionState()
        let acknowledged = state.acknowledgments[destination] ?? [:]
        let intendedPaths = state.destinationIntents?[destination] ?? []
        return state.revisions.compactMap { path, revision in
            guard !Self.excludedPaths.contains(path), acknowledged[path] != revision.revision else { return nil }
            if revision.deleted && acknowledged[path] == nil && !legacyManifest.contains(path) && !intendedPaths.contains(path) { return nil }
            return VaultSyncItem(path: path, revision: revision)
        }.sorted { $0.path < $1.path }
    }

    /// Read only when the enumerated revision is still current; newer edits remain pending.
    func snapshot(_ item: VaultSyncItem) throws -> VaultSyncSnapshot? {
        try repository.withAccess {
            let current = try repository.revisionState().revisions[item.path]
            guard current == item.revision else { return nil }
            let url = try repository.validatedURL(item.path)
            if item.revision.deleted {
                guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
                return VaultSyncSnapshot(item: item, data: nil)
            }
            let data = try Data(contentsOf: url)
            if repository.requiresEncryptedStorage && !VaultFileStore.isEncryptedData(data) { return nil }
            guard VaultRepository.hash(data) == item.revision.revision else { return nil }
            return VaultSyncSnapshot(item: item, data: data)
        }
    }

    func recordAttempt(_ item: VaultSyncItem, destination: String) throws {
        try repository.updateRevisionState { state in
            var intents = state.destinationIntents ?? [:]
            intents[destination, default: []].insert(item.path)
            state.destinationIntents = intents
        }
    }

    func acknowledge(_ item: VaultSyncItem, destination: String) throws {
        try repository.updateRevisionState { state in
            // Do not replace the current revision with the one that just finished uploading.
            state.acknowledgments[destination, default: [:]][item.path] = item.revision.revision
        }
    }

    func sync(to destination: VaultSyncDestination, beforeAcknowledgment: (() throws -> Void)? = nil) async throws {
        for item in try pending(destination: destination.identity, legacyManifest: destination.legacyManifest) {
            try Task.checkCancellation()
            guard let snapshot = try snapshot(item) else { continue }
            try recordAttempt(item, destination: destination.identity)
            try await destination.send(snapshot)
            try beforeAcknowledgment?()
            try acknowledge(item, destination: destination.identity)
        }
    }

    /// Conservative import of existing vault files and old manifests. Never infer remote ownership.
    private func reconcile(legacyManifest: Set<String>) throws {
        try repository.withAccess {
            let root = repository.rootURL
            let manager = FileManager.default
            var hashes: [String: String] = [:]
            if let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    let path = String(url.path.dropFirst(root.path.count + 1))
                    guard !Self.excludedPaths.contains(path) else { continue }
                    _ = try repository.validatedURL(path)
                    hashes[path] = VaultRepository.hash(try Data(contentsOf: url))
                }
            }
            try repository.updateRevisionState { state in
                for (path, hash) in hashes where state.revisions[path]?.revision != hash || state.revisions[path]?.deleted == true {
                    state.revisions[path] = VaultRevision(revision: hash, deleted: false, operationID: "reconcile")
                }
                let known = Set(state.revisions.keys).union(legacyManifest)
                for path in known where hashes[path] == nil && !Self.excludedPaths.contains(path) {
                    _ = try repository.validatedURL(path)
                    if state.revisions[path]?.deleted != true {
                        state.revisions[path] = VaultRevision(revision: "deleted:\(UUID().uuidString)", deleted: true, operationID: "reconcile")
                    }
                }
            }
        }
    }
}
