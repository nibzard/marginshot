import Foundation

struct VaultNoteMetadata: Codable {
    let path: String
    let noteMeta: NoteMeta
}

enum VaultNoteMetadataStore {
    static func metadataPath(for path: String) -> String {
        "_system/note-metadata/" + VaultRepository.hash(Data(path.utf8)) + ".json"
    }

    static func write(path: String, noteMeta: NoteMeta, rootURL: URL, userDefaults: UserDefaults) throws {
        let metadata = VaultNoteMetadata(path: path, noteMeta: noteMeta)
        try VaultFileStore.writeData(JSONEncoder().encode(metadata), to: rootURL.appendingPathComponent(metadataPath(for: path)), userDefaults: userDefaults)
    }
}

actor IndexWorker {
    static let shared = IndexWorker()

    @discardableResult
    func process(store: VaultIndexStore, force: Bool = false) -> Bool {
        do {
            try store.rebuildFromVault(force: force)
            return true
        } catch {
            print("Index recovery deferred: \(error)")
            return false
        }
    }
}

enum VaultProposal {
    static func bind(_ operations: [VaultFileOperation], to context: ContextBundle, userDefaults: UserDefaults = .standard) throws -> [VaultFileOperation] {
        let revisions = Dictionary(uniqueKeysWithValues: context.notes.compactMap { note in
            note.revision.map { (note.path, $0) }
        })
        return try operations.map { operation in
            let path = try VaultApplyService.normalizePath(operation.path, userDefaults: userDefaults)
            // Trust revisions captured with retrieval bytes, never model-supplied revision fields.
            return VaultFileOperation(action: operation.action, path: path, content: operation.content, noteMeta: operation.noteMeta,
                                      expectedRevision: operation.action == .create ? .missing : revisions[path])
        }
    }
}
