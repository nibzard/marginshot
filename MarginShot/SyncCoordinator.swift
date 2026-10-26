import BackgroundTasks
import Foundation
import Network
import UIKit

private final class NetworkCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

enum NetworkConstraintChecker {
    static func isNetworkAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "marginshot.network.monitor")
            let completion = NetworkCheckCompletion()
            monitor.pathUpdateHandler = { path in
                guard completion.claim() else { return }
                let satisfied = path.status == .satisfied
                monitor.cancel()
                continuation.resume(returning: satisfied)
            }
            monitor.start(queue: queue)
        }
    }

    static func isWiFiAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "marginshot.network.monitor")
            let completion = NetworkCheckCompletion()
            monitor.pathUpdateHandler = { path in
                guard completion.claim() else { return }
                let satisfied = path.status == .satisfied && path.usesInterfaceType(.wifi)
                monitor.cancel()
                continuation.resume(returning: satisfied)
            }
            monitor.start(queue: queue)
        }
    }
}

struct SyncPreferences {
    var destination: SyncDestination {
        let raw = UserDefaults.standard.string(forKey: SyncDefaults.destinationKey) ?? SyncDestination.off.rawValue
        return SyncDestination(rawValue: raw) ?? .off
    }

    var requiresWiFi: Bool {
        UserDefaults.standard.bool(forKey: SyncDefaults.wiFiOnlyKey)
    }

    var requiresExternalPower: Bool {
        UserDefaults.standard.bool(forKey: SyncDefaults.requiresChargingKey)
    }
}

enum SyncTrigger: String {
    case processing
    case applyToVault
    case manual
    case wakeup
}

enum SyncFolderSelection {
    static func resolveURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: SyncDefaults.folderBookmarkKey) else {
            return nil
        }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale, let url {
            refreshBookmark(for: url)
        }
        return url
    }

    private static func refreshBookmark(for url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: SyncDefaults.folderBookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: SyncDefaults.folderDisplayNameKey)
    }
}

private enum SyncManifestStore {
    private static let folderManifestPrefix = "sync.folder.manifest."
    private static let gitHubManifestPrefix = "sync.github.manifest."

    static func loadFolderManifest(for destinationURL: URL, userDefaults: UserDefaults = .standard) -> Set<String> {
        let key = folderManifestKey(for: destinationURL)
        let items = userDefaults.stringArray(forKey: key) ?? []
        return Set(items)
    }

    static func saveFolderManifest(_ manifest: Set<String>, for destinationURL: URL, userDefaults: UserDefaults = .standard) {
        let key = folderManifestKey(for: destinationURL)
        userDefaults.set(manifest.sorted(), forKey: key)
    }

    static func loadGitHubManifest(selection: GitHubRepoSelection) -> Set<String> {
        let key = gitHubManifestKey(for: selection)
        let items = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(items)
    }

    static func saveGitHubManifest(_ manifest: Set<String>, selection: GitHubRepoSelection) {
        let key = gitHubManifestKey(for: selection)
        UserDefaults.standard.set(manifest.sorted(), forKey: key)
    }

    private static func folderManifestKey(for destinationURL: URL) -> String {
        "\(folderManifestPrefix)\(destinationURL.standardizedFileURL.path)"
    }

    private static func gitHubManifestKey(for selection: GitHubRepoSelection) -> String {
        "\(gitHubManifestPrefix)\(selection.owner)/\(selection.name)#\(selection.branch)"
    }
}

enum FolderSyncError: Error {
    case documentsDirectoryUnavailable
    case sourceOverlap
}

struct FolderSyncDestination: VaultSyncDestination {
    let url: URL
    let userDefaults: UserDefaults
    var identity: String { "folder:" + url.standardizedFileURL.resolvingSymlinksInPath().path }
    var legacyManifest: Set<String> { SyncManifestStore.loadFolderManifest(for: url, userDefaults: userDefaults) }

    init(url: URL, source: URL, userDefaults: UserDefaults = .standard) throws {
        let destination = url.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination != sourcePath, !destination.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(destination + "/") else {
            throw FolderSyncError.sourceOverlap
        }
        self.url = url
        self.userDefaults = userDefaults
    }

    func send(_ snapshot: VaultSyncSnapshot) async throws { try apply(snapshot) }

    func apply(_ snapshot: VaultSyncSnapshot) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let path = snapshot.item.path
        let target = url.appendingPathComponent(path)
        // A destination symlink must not redirect writes/deletions to unrelated content.
        var prefix = url
        for component in path.split(separator: "/") {
            prefix.appendPathComponent(String(component))
            guard (try? manager.destinationOfSymbolicLink(atPath: prefix.path)) == nil else { throw VaultRepositoryError.invalidPath(path) }
        }
        if let data = snapshot.data {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = target.deletingLastPathComponent().appendingPathComponent(".marginshot-copy-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: staging) }
            try data.write(to: staging, options: .atomic)
            if manager.fileExists(atPath: target.path) {
                guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else { throw VaultRepositoryError.invalidPath(path) }
                _ = try manager.replaceItemAt(target, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: target)
            }
        } else if manager.fileExists(atPath: target.path) {
            // Delete owned files only; do not recursively remove unexpected directories.
            guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else { throw VaultRepositoryError.invalidPath(path) }
            try manager.removeItem(at: target)
        }
        var manifest = legacyManifest
        if snapshot.data == nil { manifest.remove(path) } else { manifest.insert(path) }
        SyncManifestStore.saveFolderManifest(manifest, for: url, userDefaults: userDefaults)
    }
}

enum FolderSyncer {
    @discardableResult
    static func syncVault(to destinationURL: URL, userDefaults: UserDefaults = .standard, rootURL: URL? = nil) throws -> Bool {
        let source: URL
        if let rootURL { source = rootURL }
        else {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw FolderSyncError.documentsDirectoryUnavailable }
            source = documents.appendingPathComponent("vault", isDirectory: true)
        }
        let repository = VaultRepository.register(rootURL: source, userDefaults: userDefaults)
        let engine = RevisionSyncEngine(repository: repository)
        let destination = try FolderSyncDestination(url: destinationURL, source: source, userDefaults: userDefaults)
        for item in try engine.pending(destination: destination.identity, legacyManifest: destination.legacyManifest) {
            guard let snapshot = try engine.snapshot(item) else { continue }
            try engine.recordAttempt(item, destination: destination.identity)
            try destination.apply(snapshot)
            try engine.acknowledge(item, destination: destination.identity)
        }
        return try engine.pending(destination: destination.identity, legacyManifest: destination.legacyManifest).isEmpty
    }
}

actor SyncCoordinator {
    static let shared = SyncCoordinator()

    private var isSyncing = false
    private var requested = false
    private let injectedEligibility: (() async -> Bool)?
    private let injectedRun: ((SyncTrigger) async throws -> Void)?
    private(set) var lastFailure: String?

    init(eligibility: (() async -> Bool)? = nil, run: ((SyncTrigger) async throws -> Void)? = nil) {
        injectedEligibility = eligibility
        injectedRun = run
    }

    func syncIfNeeded(trigger: SyncTrigger) async {
        requested = true
        guard !isSyncing else { return }
        // Claim ownership before any eligibility/status suspension.
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            requested = false
            if let injectedRun {
                if !(await injectedEligibility?() ?? true) {
                    if requested { continue }
                    return
                }
                do { try await injectedRun(trigger); lastFailure = nil }
                catch { lastFailure = error.localizedDescription }
                continue
            }
            let prefs = SyncPreferences()
            await SyncStatusStore.shared.updateDestination(prefs.destination)
            if !(await constraintsSatisfied(prefs, destination: prefs.destination)) {
                await SyncStatusStore.shared.markWaiting()
                if requested { continue }
                return
            }
            switch prefs.destination {
            case .off: return
            case .folder: await performFolderSync(trigger: trigger)
            case .github: await performGitHubSync(trigger: trigger)
            case .gitRemote: await SyncStatusStore.shared.markError("Custom Git remote sync is not available yet.")
            }
        } while requested
    }

    private func performFolderSync(trigger: SyncTrigger) async {
        guard let destinationURL = SyncFolderSelection.resolveURL() else {
            await SyncStatusStore.shared.markError("Select a folder in Settings to enable sync.")
            return
        }

        await SyncStatusStore.shared.markSyncing()

        do {
            let complete = try await Task.detached { try FolderSyncer.syncVault(to: destinationURL) }.value
            lastFailure = nil
            if complete { await SyncStatusStore.shared.markIdle() }
            else { await SyncStatusStore.shared.markWaiting() }
        } catch {
            lastFailure = error.localizedDescription
            print("Sync failed (\(trigger.rawValue)): \(error)")
            await SyncStatusStore.shared.markError("Sync failed. \(error.localizedDescription)")
        }
    }

    private func performGitHubSync(trigger: SyncTrigger) async {
        await SyncStatusStore.shared.markSyncing()

        do {
            let complete = try await performWithRetries(maxAttempts: 3, baseDelay: 2) {
                try await GitHubSyncer.syncVault()
            }
            lastFailure = nil
            if complete { await SyncStatusStore.shared.markIdle() }
            else { await SyncStatusStore.shared.markWaiting() }
        } catch let syncError as GitHubSyncError {
            if case .offline = syncError {
                print("Sync skipped (\(trigger.rawValue)): offline")
                await SyncStatusStore.shared.markIdleSkippingSync()
                return
            }
            lastFailure = syncError.localizedDescription
            print("Sync failed (\(trigger.rawValue)): \(syncError)")
            await SyncStatusStore.shared.markError(syncError.localizedDescription)
        } catch {
            lastFailure = error.localizedDescription
            print("Sync failed (\(trigger.rawValue)): \(error)")
            await SyncStatusStore.shared.markError("Sync failed. \(error.localizedDescription)")
        }
    }

    private func performWithRetries<T>(
        maxAttempts: Int,
        baseDelay: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                if attempt >= maxAttempts || !shouldRetry(error) {
                    throw error
                }
                let delay = min(baseDelay * pow(2, Double(attempt - 1)), 30)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let syncError = error as? GitHubSyncError {
            return syncError.isRetryable
        }
        return true
    }

    private func constraintsSatisfied(_ prefs: SyncPreferences, destination: SyncDestination) async -> Bool {
        if prefs.requiresExternalPower {
            let hasPower = await MainActor.run {
                UIDevice.current.isBatteryMonitoringEnabled = true
                let state = UIDevice.current.batteryState
                return state == .charging || state == .full
            }
            guard hasPower else { return false }
        }
        switch destination {
        case .github:
            if prefs.requiresWiFi {
                let wifiAvailable = await NetworkConstraintChecker.isWiFiAvailable()
                guard wifiAvailable else { return false }
            } else {
                let networkAvailable = await NetworkConstraintChecker.isNetworkAvailable()
                guard networkAvailable else { return false }
            }
        case .folder:
            if prefs.requiresWiFi {
                let wifiAvailable = await NetworkConstraintChecker.isWiFiAvailable()
                guard wifiAvailable else { return false }
            }
        default:
            break
        }
        return true
    }
}

struct GitHubRepoSelection {
    let owner: String
    let name: String
    let branch: String

    static func load() -> GitHubRepoSelection? {
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: GitHubDefaults.repoOwnerKey) ?? ""
        let name = defaults.string(forKey: GitHubDefaults.repoNameKey) ?? ""
        let branch = defaults.string(forKey: GitHubDefaults.repoBranchKey) ?? ""
        guard !owner.isEmpty, !name.isEmpty else {
            return nil
        }
        return GitHubRepoSelection(owner: owner, name: name, branch: branch.isEmpty ? "main" : branch)
    }
}

enum GitHubSyncError: LocalizedError {
    case missingToken
    case missingRepository
    case vaultUnavailable
    case unauthorized
    case rateLimited
    case serverError(Int)
    case apiError(String)
    case transportError(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Connect GitHub in Settings to enable sync."
        case .missingRepository:
            return "Select a GitHub repository in Settings to enable sync."
        case .vaultUnavailable:
            return "Vault is unavailable for GitHub sync."
        case .unauthorized:
            return "GitHub authorization expired. Sign in again."
        case .rateLimited:
            return "GitHub rate limit exceeded. Try again later."
        case .serverError(let status):
            return "GitHub server error (\(status)). Try again later."
        case .apiError(let message):
            return "GitHub sync failed. \(message)"
        case .transportError(let message):
            return "GitHub sync failed. \(message)"
        case .offline:
            return "GitHub sync skipped because you're offline."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .serverError, .transportError:
            return true
        case .offline:
            return false
        default:
            return false
        }
    }
}

enum GitHubSyncer {
    private static let fileManager = FileManager.default
    private static let excludedSearchFiles: Set<String> = [
        "_system/search.sqlite",
        "_system/search.sqlite-wal",
        "_system/search.sqlite-shm"
    ]

    @discardableResult
    static func syncVault() async throws -> Bool {
        guard let token = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) else { throw GitHubSyncError.missingToken }
        guard let selection = GitHubRepoSelection.load() else { throw GitHubSyncError.missingRepository }
        let repository = VaultRepository.register(rootURL: try vaultRootURL())
        let destination = GitHubSyncDestination(selection: selection, token: token)
        let engine = RevisionSyncEngine(repository: repository)
        try await engine.sync(to: destination)
        // Reconciliation/acknowledgments are established; old watermarks no longer govern work.
        UserDefaults.standard.removeObject(forKey: GitHubDefaults.lastSyncAtKey(owner: selection.owner, name: selection.name, branch: selection.branch))
        UserDefaults.standard.removeObject(forKey: GitHubDefaults.lastSyncAtLegacyKey)
        return try engine.pending(destination: destination.identity, legacyManifest: destination.legacyManifest).isEmpty
    }

    struct GitHubSyncDestination: VaultSyncDestination {
        let selection: GitHubRepoSelection
        let token: String
        var identity: String { "github:\(selection.owner.lowercased())/\(selection.name.lowercased())#\(selection.branch)" }
        var legacyManifest: Set<String> { SyncManifestStore.loadGitHubManifest(selection: selection) }

        func send(_ snapshot: VaultSyncSnapshot) async throws {
            do {
                let path = snapshot.item.path
                if let data = snapshot.data {
                    try await putContentWithSHAFallback(token: token, selection: selection, relativePath: path, content: data.base64EncodedString(), message: "Sync vault: \(path)")
                } else {
                    try await deleteRemovedFiles([path], selection: selection, token: token)
                }
                var manifest = legacyManifest
                if snapshot.data == nil { manifest.remove(path) } else { manifest.insert(path) }
                SyncManifestStore.saveGitHubManifest(manifest, selection: selection)
            } catch let error as GitHubSyncError { throw error }
            catch let error as GitHubAPIError { throw mapGitHubError(error) }
            catch { throw mapTransportError(error) }
        }
    }

    private static func deleteRemovedFiles(
        _ removed: Set<String>,
        selection: GitHubRepoSelection,
        token: String
    ) async throws {
        for relativePath in removed.sorted() {
            do {
                guard let sha = try await GitHubAPI.fetchContentSHA(
                    token: token,
                    owner: selection.owner,
                    repo: selection.name,
                    path: relativePath,
                    branch: selection.branch
                ) else {
                    continue
                }
                let message = "Sync vault: delete \(relativePath)"
                try await GitHubAPI.deleteContent(
                    token: token,
                    owner: selection.owner,
                    repo: selection.name,
                    path: relativePath,
                    branch: selection.branch,
                    sha: sha,
                    message: message
                )
            } catch let apiError as GitHubAPIError where apiError == .notFound {
                continue
            } catch let syncError as GitHubSyncError {
                throw syncError
            } catch let apiError as GitHubAPIError {
                throw mapGitHubError(apiError)
            } catch {
                throw mapTransportError(error)
            }
        }
    }

    private static func putContentWithSHAFallback(
        token: String,
        selection: GitHubRepoSelection,
        relativePath: String,
        content: String,
        message: String
    ) async throws {
        do {
            try await GitHubAPI.putContent(
                token: token,
                owner: selection.owner,
                repo: selection.name,
                path: relativePath,
                branch: selection.branch,
                content: content,
                message: message,
                sha: nil
            )
        } catch let apiError as GitHubAPIError where apiError == .requiresSha {
            guard let sha = try await GitHubAPI.fetchContentSHA(
                token: token,
                owner: selection.owner,
                repo: selection.name,
                path: relativePath,
                branch: selection.branch
            ) else {
                throw GitHubSyncError.apiError("Missing remote file SHA for \(relativePath).")
            }
            try await GitHubAPI.putContent(
                token: token,
                owner: selection.owner,
                repo: selection.name,
                path: relativePath,
                branch: selection.branch,
                content: content,
                message: message,
                sha: sha
            )
        }
    }

    private static func mapGitHubError(_ error: GitHubAPIError) -> GitHubSyncError {
        switch error {
        case .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        case .serverError(let status, _):
            return .serverError(status)
        case .notFound:
            return .apiError("Repository or path not found.")
        case .invalidResponse:
            return .transportError("Invalid response from GitHub.")
        case .requiresSha:
            return .apiError("GitHub requires a file SHA to update content.")
        case .apiError(let message):
            return .apiError(message)
        }
    }

    private static func mapTransportError(_ error: Error) -> GitHubSyncError {
        if let urlError = error as? URLError, isOfflineError(urlError) {
            return .offline
        }
        return .transportError(error.localizedDescription)
    }

    private static func isOfflineError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw GitHubSyncError.vaultUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    private static func relativePath(from baseURL: URL, to fileURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else {
            return fileURL.lastPathComponent
        }
        var relative = String(filePath.dropFirst(basePath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }
}

struct GitHubUser: Decodable {
    let login: String
}

struct GitHubRepo: Identifiable, Decodable {
    let id: Int
    let name: String
    let fullName: String
    let owner: GitHubRepoOwner
    let isPrivate: Bool
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case owner
        case isPrivate = "private"
        case defaultBranch = "default_branch"
    }
}

struct GitHubRepoOwner: Decodable {
    let login: String
}

struct GitHubContentResponse: Decodable {
    let sha: String
}

struct GitHubCreateContentRequest: Encodable {
    let message: String
    let content: String
    let branch: String
    let sha: String?
}

struct GitHubDeleteContentRequest: Encodable {
    let message: String
    let sha: String
    let branch: String
}

struct GitHubTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

struct GitHubAPIErrorResponse: Decodable {
    let message: String?
}

enum GitHubAPIError: Error, Equatable {
    case invalidResponse
    case unauthorized
    case notFound
    case rateLimited
    case requiresSha
    case serverError(Int, String?)
    case apiError(String)
}

enum GitHubAPI {
    private static let baseURL = URL(string: "https://api.github.com")!

    static func fetchUser(token: String) async throws -> GitHubUser {
        let url = baseURL.appendingPathComponent("user")
        let request = authorizedRequest(url: url, token: token)
        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode(GitHubUser.self, from: data)
    }

    static func fetchRepos(token: String) async throws -> [GitHubRepo] {
        var components = URLComponents(url: baseURL.appendingPathComponent("user/repos"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member")
        ]
        guard let url = components?.url else {
            throw GitHubAPIError.invalidResponse
        }
        let request = authorizedRequest(url: url, token: token)
        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode([GitHubRepo].self, from: data)
    }

    static func fetchContentSHA(
        token: String,
        owner: String,
        repo: String,
        path: String,
        branch: String
    ) async throws -> String? {
        var components = URLComponents(url: contentsURL(owner: owner, repo: repo, path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "ref", value: branch)
        ]
        guard let url = components?.url else {
            throw GitHubAPIError.invalidResponse
        }
        let request = authorizedRequest(url: url, token: token)
        do {
            let (data, _) = try await performRequest(request)
            let response = try JSONDecoder().decode(GitHubContentResponse.self, from: data)
            return response.sha
        } catch let error as GitHubAPIError where error == .notFound {
            return nil
        }
    }

    static func putContent(
        token: String,
        owner: String,
        repo: String,
        path: String,
        branch: String,
        content: String,
        message: String,
        sha: String?
    ) async throws {
        let url = contentsURL(owner: owner, repo: repo, path: path)
        var request = authorizedRequest(url: url, token: token, method: "PUT")
        let payload = GitHubCreateContentRequest(
            message: message,
            content: content,
            branch: branch,
            sha: sha
        )
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        if (200...299).contains(http.statusCode) {
            return
        }
        if http.statusCode == 422 {
            throw GitHubAPIError.requiresSha
        }
        try handleError(data, response: http)
    }

    static func deleteContent(
        token: String,
        owner: String,
        repo: String,
        path: String,
        branch: String,
        sha: String,
        message: String
    ) async throws {
        let url = contentsURL(owner: owner, repo: repo, path: path)
        var request = authorizedRequest(url: url, token: token, method: "DELETE")
        let payload = GitHubDeleteContentRequest(message: message, sha: sha, branch: branch)
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        if (200...299).contains(http.statusCode) {
            return
        }
        try handleError(data, response: http)
    }

    static func exchangeCodeForToken(
        clientID: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> String {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw GitHubAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = formURLEncoded([
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ])
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            try handleError(data, response: http)
        }
        let tokenResponse = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)
        if let accessToken = tokenResponse.accessToken {
            return accessToken
        }
        if let errorDescription = tokenResponse.errorDescription {
            throw GitHubAPIError.apiError(errorDescription)
        }
        throw GitHubAPIError.apiError("Missing access token.")
    }

    private static func authorizedRequest(url: URL, token: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MarginShot", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        if (200...299).contains(http.statusCode) {
            return (data, http)
        }
        try handleError(data, response: http)
    }

    private static func handleError(_ data: Data, response: HTTPURLResponse) throws -> Never {
        let message = (try? JSONDecoder().decode(GitHubAPIErrorResponse.self, from: data))?.message
        if response.statusCode == 401 {
            throw GitHubAPIError.unauthorized
        }
        if response.statusCode == 404 {
            throw GitHubAPIError.notFound
        }
        if response.statusCode == 403,
           response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw GitHubAPIError.rateLimited
        }
        if (500...599).contains(response.statusCode) {
            throw GitHubAPIError.serverError(response.statusCode, message)
        }
        throw GitHubAPIError.apiError(message ?? "HTTP \(response.statusCode)")
    }

    private static func contentsURL(owner: String, repo: String, path: String) -> URL {
        var url = baseURL.appendingPathComponent("repos")
        url.appendPathComponent(owner)
        url.appendPathComponent(repo)
        url.appendPathComponent("contents")
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private static let rfc3986AllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func formURLEncoded(_ parameters: [String: String]) -> String {
        parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: rfc3986AllowedCharacters) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: rfc3986AllowedCharacters) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }
}

extension Notification.Name {
    static let vaultDidCommit = Notification.Name("MarginShot.vaultDidCommit")
}

@MainActor
final class SyncWakeupObserver {
    static let shared = SyncWakeupObserver()
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [Notification.Name.vaultDidCommit, UIDevice.batteryStateDidChangeNotification,
                     UIApplication.didBecomeActiveNotification, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Self.shared.wake() }
            })
        }
        monitor.pathUpdateHandler = { _ in Task { @MainActor in Self.shared.wake() } }
        monitor.start(queue: DispatchQueue(label: "marginshot.sync.wakeups"))
        wake()
    }

    private func wake() {
        ProcessingQueue.shared.enqueuePendingProcessing()
        Task { await SyncCoordinator.shared.syncIfNeeded(trigger: .wakeup) }
        Task.detached { _ = await IndexWorker.shared.process(store: .shared) }
    }
}

// iOS chooses when eligible backup work runs; foreground/manual wakeups use the same coordinator.
enum SyncBackgroundScheduler {
    private static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.example.MarginShot") + ".backup" }

    static func register() {
        #if !targetEnvironment(simulator)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task {
                do {
                    try await AppRecovery.shared.prepare()
                    await SyncCoordinator.shared.syncIfNeeded(trigger: .wakeup)
                    task.setTaskCompleted(success: await SyncCoordinator.shared.lastFailure == nil)
                } catch { task.setTaskCompleted(success: false) }
                schedule()
            }
            task.expirationHandler = { work.cancel() }
        }
        #endif
    }

    static func schedule() {
        #if !targetEnvironment(simulator)
        let preferences = SyncPreferences()
        guard preferences.destination != .off else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = preferences.destination == .github
        request.requiresExternalPower = preferences.requiresExternalPower
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { print("Backup scheduling deferred: \(error)") }
        #endif
    }
}
