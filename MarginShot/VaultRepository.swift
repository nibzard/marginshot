import CryptoKit
import Foundation

enum VaultRepositoryError: Error, LocalizedError {
    case invalidPath(String)
    case staleRevision(String)
    case recoveryConflict(String)
    case corruptStaging(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Invalid vault path: \(path)"
        case .staleRevision(let path): return "\(path) changed. Refresh and review the proposal again."
        case .recoveryConflict(let path): return "Vault recovery needs attention for \(path). Recovery copies have been preserved."
        case .corruptStaging(let path): return "Recovery data is unavailable for \(path). Recovery copies have been preserved."
        }
    }
}

enum VaultExpectedRevision: Codable, Equatable {
    case missing
    case hash(String)
}

struct VaultRevision: Codable, Equatable {
    let revision: String
    let deleted: Bool
    let operationID: String
}

struct VaultRevisionState: Codable {
    var revisions: [String: VaultRevision] = [:]
    var acknowledgments: [String: [String: String]] = [:]
    var indexed: [String: String] = [:]
    var destinationIntents: [String: Set<String>]?
}

/// Synchronous storage boundary. Never suspend or perform networking in a transaction.
final class VaultRepository {
    enum Checkpoint: Equatable {
        case staged
        case prepared
        case applied(Int)
        case revisions
        case committed
    }

    private struct Mutation: Codable {
        let path: String
        let oldHash: String?
        let newHash: String?
        let stagedName: String?
        let beforeName: String?
    }

    private struct Intent: Codable {
        let version: Int
        let id: String
        let mutations: [Mutation]
        let result: Data
    }

    private enum Change {
        case write(Data)
        case delete
    }

    private final class Preparation {
        let root: URL
        var changes: [String: Change] = [:]
        init(root: URL) { self.root = root }
    }

    private static let lock = NSRecursiveLock()
    private static var repositories: [String: VaultRepository] = [:]
    private static let preparationKey = "MarginShot.VaultRepository.preparation"
    private static var preparation: Preparation? {
        get { Thread.current.threadDictionary[preparationKey] as? Preparation }
        set { Thread.current.threadDictionary[preparationKey] = newValue }
    }

    let rootURL: URL
    var requiresEncryptedStorage: Bool { VaultFileStore.isEncryptionEnabled(userDefaults: userDefaults) }
    private let userDefaults: UserDefaults
    let encryptionKey: SymmetricKey?
    private let fileManager = FileManager.default
    var checkpoint: ((Checkpoint) throws -> Void)?

    init(rootURL: URL, userDefaults: UserDefaults = .standard, encryptionKey: SymmetricKey? = nil) {
        self.encryptionKey = encryptionKey
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.userDefaults = userDefaults
    }

    @discardableResult
    static func register(rootURL: URL, userDefaults: UserDefaults = .standard, encryptionKey: SymmetricKey? = nil) -> VaultRepository {
        lock.lock()
        defer { lock.unlock() }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = repositories[root.path] { return existing }
        let repository = VaultRepository(rootURL: root, userDefaults: userDefaults, encryptionKey: encryptionKey)
        repositories[root.path] = repository
        return repository
    }

    private static func containing(_ url: URL) -> VaultRepository? {
        // All app paths share this root. Tests explicitly register their temporary roots.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            register(rootURL: documents.appendingPathComponent("vault", isDirectory: true))
        }
        let path = url.standardizedFileURL.path
        return repositories.values.filter { path.hasPrefix($0.rootURL.path + "/") }.max { $0.rootURL.path.count < $1.rootURL.path.count }
    }

    static func encryptionKey(for url: URL) -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return containing(url)?.encryptionKey
    }

    static func readStoredData(from url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let repository = containing(url) else { return try Data(contentsOf: url) }
        let path = try repository.relativePath(url)
        if let preparation, preparation.root == repository.rootURL {
            if let change = preparation.changes[path] {
                switch change {
                case .write(let data): return data
                case .delete: throw CocoaError(.fileReadNoSuchFile)
                }
            }
        } else {
            try repository.recoverLocked()
        }
        return try Data(contentsOf: url)
    }

    static func writeStoredData(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let repository = containing(url) else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return
        }
        let path = try repository.relativePath(url)
        if let preparation, preparation.root == repository.rootURL {
            preparation.changes[path] = .write(data)
        } else {
            let _: Bool = try repository.transaction {
                Self.preparation!.changes[path] = .write(data)
                return true
            }
        }
    }

    static func removeItem(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let repository = containing(url) else {
            try FileManager.default.removeItem(at: url)
            return
        }
        let path = try repository.relativePath(url)
        if let preparation, preparation.root == repository.rootURL {
            preparation.changes[path] = .delete
        } else {
            let _: Bool = try repository.transaction {
                Self.preparation!.changes[path] = .delete
                return true
            }
        }
    }

    func withAccess<T>(_ body: () throws -> T) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if Self.preparation == nil { try recoverLocked() }
        return try body()
    }

    func transaction<T: Codable>(
        id: String = UUID().uuidString,
        expected: [String: VaultExpectedRevision] = [:],
        _ body: () throws -> T
    ) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let current = Self.preparation {
            guard current.root == rootURL else { throw VaultRepositoryError.invalidPath(rootURL.path) }
            return try body()
        }
        try recoverLocked()
        let receipt = receiptURL(id)
        if fileManager.fileExists(atPath: receipt.path) {
            return try JSONDecoder().decode(T.self, from: VaultFileStore.decryptDataIfNeeded(Data(contentsOf: receipt), userDefaults: userDefaults, key: encryptionKey))
        }
        for (path, revision) in expected {
            let url = try validatedURL(path)
            let actual = try storedHash(url)
            let matches = revision == (actual.map { .hash($0) } ?? .missing)
            guard matches else { throw VaultRepositoryError.staleRevision(path) }
        }
        let preparation = Preparation(root: rootURL)
        Self.preparation = preparation
        let result: T
        do {
            result = try body()
        } catch {
            Self.preparation = nil
            throw error
        }
        Self.preparation = nil
        let directory = operationURL(id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var mutations: [Mutation] = []
        for (index, path) in preparation.changes.keys.sorted().enumerated() {
            let url = try validatedURL(path)
            let oldData = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let beforeName = oldData.map { _ in "\(index).before" }
            if let oldData, let beforeName { try VaultFileStore.encryptDataIfNeeded(oldData, userDefaults: userDefaults, key: encryptionKey).write(to: directory.appendingPathComponent(beforeName), options: .atomic) }
            let data: Data?
            switch preparation.changes[path]! {
            case .write(let output): data = try VaultFileStore.encryptDataIfNeeded(output, userDefaults: userDefaults, key: encryptionKey)
            case .delete: data = nil
            }
            let stagedName = data.map { _ in "\(index).after" }
            if let data, let stagedName { try data.write(to: directory.appendingPathComponent(stagedName), options: .atomic) }
            mutations.append(Mutation(path: path, oldHash: oldData.map(Self.hash), newHash: data.map(Self.hash), stagedName: stagedName, beforeName: beforeName))
        }
        try checkpoint?(.staged)
        let encodedResult = try VaultFileStore.encryptDataIfNeeded(JSONEncoder().encode(result), userDefaults: userDefaults, key: encryptionKey)
        let intent = Intent(version: 1, id: id, mutations: mutations, result: encodedResult)
        try JSONEncoder().encode(intent).write(to: directory.appendingPathComponent("intent.json"), options: .atomic)
        try checkpoint?(.prepared)
        try finish(intent, directory: directory, injectFailures: true)
        return result
    }

    func recover() throws { try withAccess {} }

    func revision(for path: String) throws -> VaultExpectedRevision {
        try withAccess {
            let url = try validatedURL(path)
            return try storedHash(url).map { .hash($0) } ?? .missing
        }
    }

    func revisionState() throws -> VaultRevisionState {
        try withAccess { try loadState() }
    }

    func updateRevisionState(_ update: (inout VaultRevisionState) throws -> Void) throws {
        try withAccess {
            var state = try loadState()
            try update(&state)
            try saveState(state)
        }
    }

    func encryptRecoveryArtifacts() throws {
        try withAccess {
            // Pending intents have been recovered. Remaining operation directories are unprepared staging.
            for name in ["receipts", "operations"] {
                let directory = internalURL.appendingPathComponent(name)
                guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let url as URL in enumerator {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    let data = try Data(contentsOf: url)
                    try VaultFileStore.encryptDataIfNeeded(data, userDefaults: userDefaults, key: encryptionKey).write(to: url, options: .atomic)
                }
            }
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validatedURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              components.first != ".marginshot" else { throw VaultRepositoryError.invalidPath(path) }
        var prefix = rootURL
        for component in components {
            prefix.appendPathComponent(String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: prefix.path)) != nil {
                throw VaultRepositoryError.invalidPath(path)
            }
        }
        let url = rootURL.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(rootURL.path + "/") else {
            throw VaultRepositoryError.invalidPath(path)
        }
        return url
    }

    private func relativePath(_ url: URL) throws -> String {
        let prefix = rootURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw VaultRepositoryError.invalidPath(url.path) }
        let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        _ = try validatedURL(path)
        return path
    }

    private var internalURL: URL { rootURL.appendingPathComponent(".marginshot", isDirectory: true) }
    private func operationURL(_ id: String) -> URL { internalURL.appendingPathComponent("operations/" + Self.hash(Data(id.utf8)), isDirectory: true) }
    private func receiptURL(_ id: String) -> URL { internalURL.appendingPathComponent("receipts/" + Self.hash(Data(id.utf8))) }

    private func recoverLocked() throws {
        let operations = internalURL.appendingPathComponent("operations", isDirectory: true)
        guard fileManager.fileExists(atPath: operations.path) else { return }
        for directory in try fileManager.contentsOfDirectory(at: operations, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            let intentURL = directory.appendingPathComponent("intent.json")
            guard fileManager.fileExists(atPath: intentURL.path) else { continue }
            let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: intentURL))
            guard intent.version == 1 else { throw VaultRepositoryError.corruptStaging(directory.lastPathComponent) }
            try finish(intent, directory: directory, injectFailures: false)
        }
    }

    private func finish(_ intent: Intent, directory: URL, injectFailures: Bool) throws {
        if !fileManager.fileExists(atPath: receiptURL(intent.id).path) {
            // Validate the complete intent before touching any live file.
            for mutation in intent.mutations {
                let url = try validatedURL(mutation.path)
                let current = try storedHash(url)
                guard current == mutation.oldHash || current == mutation.newHash else {
                    throw VaultRepositoryError.recoveryConflict(mutation.path)
                }
                if let stagedName = mutation.stagedName {
                    let staged = directory.appendingPathComponent(stagedName)
                    guard try Self.hash(Data(contentsOf: staged)) == mutation.newHash else {
                        throw VaultRepositoryError.corruptStaging(mutation.path)
                    }
                }
            }
            for (index, mutation) in intent.mutations.enumerated() {
                let url = try validatedURL(mutation.path)
                if let stagedName = mutation.stagedName {
                    let data = try Data(contentsOf: directory.appendingPathComponent(stagedName))
                    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                if injectFailures { try checkpoint?(.applied(index)) }
            }
            var state = try loadState()
            for mutation in intent.mutations {
                state.revisions[mutation.path] = VaultRevision(revision: mutation.newHash ?? "deleted:\(intent.id)", deleted: mutation.newHash == nil, operationID: intent.id)
            }
            try saveState(state)
            if injectFailures { try checkpoint?(.revisions) }
            let receipt = receiptURL(intent.id)
            try fileManager.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try intent.result.write(to: receipt, options: .atomic)
            if injectFailures { try checkpoint?(.committed) }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .vaultDidCommit, object: nil) }
        }
        try fileManager.removeItem(at: directory)
    }

    private func storedHash(_ url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return Self.hash(try Data(contentsOf: url))
    }

    private func loadState() throws -> VaultRevisionState {
        let url = internalURL.appendingPathComponent("revisions.json")
        guard fileManager.fileExists(atPath: url.path) else { return VaultRevisionState() }
        return try JSONDecoder().decode(VaultRevisionState.self, from: Data(contentsOf: url))
    }

    private func saveState(_ state: VaultRevisionState) throws {
        try fileManager.createDirectory(at: internalURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: internalURL.appendingPathComponent("revisions.json"), options: .atomic)
    }
}
