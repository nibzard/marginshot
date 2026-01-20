import CoreData
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct IndexNoteEntry: Codable, Equatable {
    let path: String
    let title: String
    let summary: String?
    let tags: [String]?
    let links: [String]?
    var updatedAt: String?
}

struct IndexSnapshot: Codable {
    var generatedAt: String?
    var notes: [IndexNoteEntry]

    init(generatedAt: String? = nil, notes: [IndexNoteEntry] = []) {
        self.generatedAt = generatedAt
        self.notes = notes
    }
}

struct ContextNote: Codable, Equatable {
    let path: String
    let title: String
    let summary: String?
    let tags: [String]?
    let links: [String]?
    let excerpt: String?
    let body: String?
}

struct ContextSource: Codable, Equatable {
    let path: String
    let title: String
}

struct ContextBundle: Codable {
    let query: String
    let generatedAt: String?
    let notes: [ContextNote]
    let sources: [ContextSource]
}

enum VaultIndexError: Error {
    case vaultRootUnavailable
    case sqliteOpenFailed
    case sqlitePrepareFailed
    case sqliteStepFailed
}

final class VaultIndexStore {
    static let shared = VaultIndexStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let isoFormatter: ISO8601DateFormatter
    private let sqliteQueue = DispatchQueue(label: "marginshot.index.sqlite")
    private let persistenceController: PersistenceController

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime]
        self.persistenceController = PersistenceController.shared
    }

    func updateAfterNoteWrite(
        notePath: String,
        noteTitle: String,
        noteMeta: NoteMeta,
        context: NSManagedObjectContext?
    ) async {
        do {
            let rootURL = try vaultRootURL()
            let noteURL = rootURL.appendingPathComponent(notePath)
            let noteBody = (try? VaultFileStore.readText(from: noteURL)) ?? ""
            let now = Date()
            var entry = IndexNoteEntry(
                path: notePath,
                title: noteTitle,
                summary: noteMeta.summary,
                tags: noteMeta.tags,
                links: noteMeta.links,
                updatedAt: nil
            )
            entry.updatedAt = isoFormatter.string(from: now)

            let notesCount = try updateIndexJSON(entry: entry, rootURL: rootURL, updatedAt: now)
            try updateStructureFile(rootURL: rootURL)
            try updateSearchStore(entry: entry, body: noteBody, rootURL: rootURL)
            await updateIndexEntity(context: context, notesCount: notesCount, updatedAt: now)
        } catch {
            print("Index update failed: \(error)")
        }
    }

    func removeNote(path: String, context: NSManagedObjectContext?) async {
        do {
            let rootURL = try vaultRootURL()
            let now = Date()
            let notesCount = try removeFromIndexJSON(path: path, rootURL: rootURL, updatedAt: now)
            try updateStructureFile(rootURL: rootURL)
            try removeFromSearchStore(path: path, rootURL: rootURL)
            await updateIndexEntity(context: context, notesCount: notesCount, updatedAt: now)
        } catch {
            print("Index removal failed: \(error)")
        }
    }

    func rebuildSearchIndex() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let rootURL = try self.vaultRootURL()
                if VaultFileStore.isEncryptionEnabled() {
                    self.removeSearchStoreFiles(rootURL: rootURL)
                    return
                }
                let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
                let snapshot = self.loadIndexSnapshot(from: indexURL)
                try self.rebuildSearchStore(entries: snapshot.notes, rootURL: rootURL)
            } catch {
                print("Search index rebuild failed: \(error)")
            }
        }
    }

    func retrieveContextBundle(
        query: String,
        preferredBatchId: UUID? = nil,
        maxResults: Int = 6,
        maxLinkedNotes: Int = 4,
        maxCharactersPerNote: Int = 2000
    ) async -> ContextBundle {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedAt = isoFormatter.string(from: Date())
        guard !trimmedQuery.isEmpty else {
            return ContextBundle(query: query, generatedAt: generatedAt, notes: [], sources: [])
        }

        do {
            let rootURL = try vaultRootURL()
            let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
            let snapshot = loadIndexSnapshot(from: indexURL)
            let searchMatches = try searchStore(
                query: trimmedQuery,
                rootURL: rootURL,
                limit: max(1, maxResults * 2)
            )
            let tokens = tokenizeQuery(trimmedQuery)
            let linkingEnabled = OrganizationPreferences().linkingEnabled

            var selectedEntries: [IndexNoteEntry] = []
            var selectedPaths = Set<String>()
            var snippetByPath: [String: String] = [:]

            if let preferredBatchId {
                let batchEntries = await loadBatchEntries(
                    batchId: preferredBatchId,
                    snapshot: snapshot,
                    rootURL: rootURL,
                    maxNotes: maxResults
                )
                for entry in batchEntries {
                    guard selectedPaths.insert(entry.path).inserted else { continue }
                    selectedEntries.append(entry)
                }
            }

            if selectedEntries.count < maxResults {
                for match in searchMatches {
                    let entry = snapshot.notes.first(where: { $0.path == match.path })
                        ?? fallbackEntry(path: match.path, title: match.title)
                    guard selectedPaths.insert(entry.path).inserted else { continue }
                    selectedEntries.append(entry)
                    if let snippet = match.snippet, !snippet.isEmpty {
                        snippetByPath[entry.path] = snippet
                    }
                    if selectedEntries.count >= maxResults {
                        break
                    }
                }
            }

            if selectedEntries.count < maxResults, !tokens.isEmpty {
                let ranked = rankIndexEntries(snapshot.notes, tokens: tokens, includeLinks: linkingEnabled)
                for scored in ranked {
                    guard selectedEntries.count < maxResults else { break }
                    if selectedPaths.insert(scored.entry.path).inserted {
                        selectedEntries.append(scored.entry)
                    }
                }
            }

            let linkLookup = linkingEnabled ? buildLinkLookup(snapshot.notes) : [:]
            var linkedEntries: [IndexNoteEntry] = []
            if linkingEnabled, maxLinkedNotes > 0 {
                for entry in selectedEntries {
                    guard linkedEntries.count < maxLinkedNotes else { break }
                    let linkCandidates = collectLinks(from: entry, snippetByPath: snippetByPath)
                    for link in linkCandidates {
                        guard linkedEntries.count < maxLinkedNotes else { break }
                        let normalized = normalizedLinkKey(link)
                        guard !normalized.isEmpty, let linked = linkLookup[normalized] else { continue }
                        guard selectedPaths.insert(linked.path).inserted else { continue }
                        linkedEntries.append(linked)
                    }
                }
            }

            let allEntries = selectedEntries + linkedEntries
            let notes = allEntries.map { entry -> ContextNote in
                let body = loadNoteBody(path: entry.path, maxCharacters: maxCharactersPerNote)
                let excerpt = snippetByPath[entry.path] ?? makeExcerpt(from: body, maxCharacters: 240)
                return ContextNote(
                    path: entry.path,
                    title: entry.title,
                    summary: entry.summary,
                    tags: entry.tags,
                    links: linkingEnabled ? entry.links : nil,
                    excerpt: excerpt,
                    body: body
                )
            }
            let sources = allEntries.map { ContextSource(path: $0.path, title: $0.title) }
            return ContextBundle(query: query, generatedAt: generatedAt, notes: notes, sources: sources)
        } catch {
            return ContextBundle(query: query, generatedAt: generatedAt, notes: [], sources: [])
        }
    }

    private func updateIndexJSON(entry: IndexNoteEntry, rootURL: URL, updatedAt: Date) throws -> Int {
        let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
        var snapshot = loadIndexSnapshot(from: indexURL)

        if let index = snapshot.notes.firstIndex(where: { $0.path == entry.path }) {
            snapshot.notes[index] = entry
        } else {
            snapshot.notes.append(entry)
        }

        snapshot.notes.sort { $0.path < $1.path }
        snapshot.generatedAt = isoFormatter.string(from: updatedAt)

        let data = try encoder.encode(snapshot)
        try VaultFileStore.writeData(data, to: indexURL)
        return snapshot.notes.count
    }

    private func removeFromIndexJSON(path: String, rootURL: URL, updatedAt: Date) throws -> Int {
        let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
        var snapshot = loadIndexSnapshot(from: indexURL)
        snapshot.notes.removeAll { $0.path == path }
        snapshot.notes.sort { $0.path < $1.path }
        snapshot.generatedAt = isoFormatter.string(from: updatedAt)
        let data = try encoder.encode(snapshot)
        try VaultFileStore.writeData(data, to: indexURL)
        return snapshot.notes.count
    }

    private func loadIndexSnapshot(from url: URL) -> IndexSnapshot {
        guard let data = try? VaultFileStore.readData(from: url) else {
            return IndexSnapshot(notes: [])
        }
        if let snapshot = try? decoder.decode(IndexSnapshot.self, from: data) {
            return snapshot
        }
        return IndexSnapshot(notes: [])
    }

    private func updateStructureFile(rootURL: URL) throws {
        let items = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let sortedItems = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = ["vault/"]

        for item in sortedItems {
            let name = item.lastPathComponent
            let isDir = isDirectory(item)
            lines.append(isDir ? "\(name)/" : name)

            guard isDir else { continue }
            let childItems = (try? fileManager.contentsOfDirectory(
                at: item,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let sortedChildren = childItems.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in sortedChildren {
                let childName = child.lastPathComponent
                let childIsDir = isDirectory(child)
                lines.append("  \(childName)\(childIsDir ? "/" : "")")
            }
        }

        let structureURL = rootURL.appendingPathComponent("_system/STRUCTURE.txt")
        let contents = lines.joined(separator: "\n") + "\n"
        try VaultFileStore.writeText(contents, to: structureURL)
    }

    private func updateSearchStore(entry: IndexNoteEntry, body: String, rootURL: URL) throws {
        if VaultFileStore.isEncryptionEnabled() {
            removeSearchStoreFiles(rootURL: rootURL)
            return
        }
        let searchURL = rootURL.appendingPathComponent("_system/search.sqlite")
        try fileManager.createDirectory(at: searchURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try withSQLite {
            var db: OpaquePointer?
            guard sqlite3_open(searchURL.path, &db) == SQLITE_OK else {
                throw VaultIndexError.sqliteOpenFailed
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            try createSearchTable(db)
            try deleteEntry(db, path: entry.path)
            try insertEntry(db, entry: entry, body: body)
        }
    }

    private func rebuildSearchStore(entries: [IndexNoteEntry], rootURL: URL) throws {
        let searchURL = rootURL.appendingPathComponent("_system/search.sqlite")
        try fileManager.createDirectory(at: searchURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try withSQLite {
            removeSearchStoreFiles(rootURL: rootURL)
            var db: OpaquePointer?
            guard sqlite3_open(searchURL.path, &db) == SQLITE_OK else {
                throw VaultIndexError.sqliteOpenFailed
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            try createSearchTable(db)
            for entry in entries {
                guard let body = loadNoteBodyFull(path: entry.path) else { continue }
                try insertEntry(db, entry: entry, body: body)
            }
        }
    }

    private func removeFromSearchStore(path: String, rootURL: URL) throws {
        if VaultFileStore.isEncryptionEnabled() {
            removeSearchStoreFiles(rootURL: rootURL)
            return
        }
        let searchURL = rootURL.appendingPathComponent("_system/search.sqlite")
        guard fileManager.fileExists(atPath: searchURL.path) else {
            return
        }

        try withSQLite {
            var db: OpaquePointer?
            guard sqlite3_open(searchURL.path, &db) == SQLITE_OK else {
                throw VaultIndexError.sqliteOpenFailed
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            try createSearchTable(db)
            try deleteEntry(db, path: path)
        }
    }

    private struct SearchMatch {
        let path: String
        let title: String?
        let snippet: String?
    }

    private struct BatchScanPath {
        let imagePath: String
        let processedImagePath: String?
        let capturedAt: Date
    }

    private struct BatchMetadataReference: Decodable {
        let notePath: String
        let noteTitle: String?
    }

    private struct ScoredEntry {
        let entry: IndexNoteEntry
        let score: Int
    }

    private func searchStore(query: String, rootURL: URL, limit: Int) throws -> [SearchMatch] {
        if VaultFileStore.isEncryptionEnabled() {
            return []
        }
        let searchURL = rootURL.appendingPathComponent("_system/search.sqlite")
        guard fileManager.fileExists(atPath: searchURL.path) else {
            return []
        }

        return try withSQLite {
            var db: OpaquePointer?
            guard sqlite3_open(searchURL.path, &db) == SQLITE_OK else {
                throw VaultIndexError.sqliteOpenFailed
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            try createSearchTable(db)

            let sql = """
            SELECT path, title, snippet(notes, 2, '', '', ' ... ', 12) AS snippet
            FROM notes
            WHERE notes MATCH ?
            ORDER BY bm25(notes)
            LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw VaultIndexError.sqlitePrepareFailed
            }
            defer { sqlite3_finalize(statement) }

            let tokens = tokenizeQuery(query)
            let ftsQuery = buildFTSQuery(from: tokens, fallback: query)
            bindText(statement, index: 1, value: ftsQuery)
            sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

            var matches: [SearchMatch] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pathText = sqlite3_column_text(statement, 0) else { continue }
                let path = String(cString: pathText)
                let title = stringColumn(statement, index: 1)
                let snippet = stringColumn(statement, index: 2)
                matches.append(SearchMatch(path: path, title: title, snippet: snippet))
            }
            return matches
        }
    }

    private func tokenizeQuery(_ query: String) -> [String] {
        let cleaned = query.replacingOccurrences(of: "\"", with: " ")
        let tokens = cleaned
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return Array(tokens.prefix(8))
    }

    private func buildFTSQuery(from tokens: [String], fallback: String) -> String {
        let trimmedTokens = tokens.filter { !$0.isEmpty }
        guard !trimmedTokens.isEmpty else {
            return fallback
        }
        return trimmedTokens.map { "\($0)*" }.joined(separator: " OR ")
    }

    private func rankIndexEntries(
        _ entries: [IndexNoteEntry],
        tokens: [String],
        includeLinks: Bool
    ) -> [ScoredEntry] {
        guard !tokens.isEmpty else { return [] }
        let tokenSet = Set(tokens)
        let scored = entries.compactMap { entry -> ScoredEntry? in
            let title = entry.title.lowercased()
            let summary = (entry.summary ?? "").lowercased()
            let tags = (entry.tags ?? []).joined(separator: " ").lowercased()
            let links = includeLinks ? (entry.links ?? []).joined(separator: " ").lowercased() : ""
            var score = 0
            for token in tokenSet {
                if title.contains(token) {
                    score += 3
                }
                if summary.contains(token) {
                    score += 2
                }
                if tags.contains(token) {
                    score += 1
                }
                if links.contains(token) {
                    score += 1
                }
            }
            guard score > 0 else { return nil }
            return ScoredEntry(entry: entry, score: score)
        }
        return scored.sorted {
            if $0.score == $1.score {
                return $0.entry.path < $1.entry.path
            }
            return $0.score > $1.score
        }
    }

    private func loadBatchEntries(
        batchId: UUID,
        snapshot: IndexSnapshot,
        rootURL: URL,
        maxNotes: Int
    ) async -> [IndexNoteEntry] {
        let scanPaths = await loadBatchScanPaths(batchId: batchId)
        guard !scanPaths.isEmpty, maxNotes > 0 else { return [] }

        var entries: [IndexNoteEntry] = []
        var seenPaths = Set<String>()
        for scan in scanPaths {
            guard let metadata = loadBatchMetadata(for: scan, rootURL: rootURL) else { continue }
            let path = metadata.notePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }
            let title = resolvedNoteTitle(path: path, title: metadata.noteTitle)
            let entry = snapshot.notes.first(where: { $0.path == path })
                ?? IndexNoteEntry(
                    path: path,
                    title: title,
                    summary: nil,
                    tags: nil,
                    links: nil,
                    updatedAt: nil
                )
            entries.append(entry)
            if entries.count >= maxNotes {
                break
            }
        }
        return entries
    }

    private func loadBatchScanPaths(batchId: UUID) async -> [BatchScanPath] {
        let context = persistenceController.container.newBackgroundContext()
        return await context.perform {
            let request = ScanEntity.fetchRequest()
            request.predicate = NSPredicate(format: "batch.id == %@", batchId as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            do {
                return try context.fetch(request).map { scan in
                    BatchScanPath(
                        imagePath: scan.imagePath,
                        processedImagePath: scan.processedImagePath,
                        capturedAt: scan.createdAt
                    )
                }
            } catch {
                return []
            }
        }
    }

    private func loadBatchMetadata(for scan: BatchScanPath, rootURL: URL) -> BatchMetadataReference? {
        let imagePath = scan.processedImagePath ?? scan.imagePath
        let metadataPath = VaultScanStore.metadataPath(for: imagePath)
        let metadataURL = rootURL.appendingPathComponent(metadataPath)
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? VaultFileStore.readData(from: metadataURL) else {
            return nil
        }
        return try? decoder.decode(BatchMetadataReference.self, from: data)
    }

    private func resolvedNoteTitle(path: String, title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? titleFromPath(path) : trimmed
    }

    private func buildLinkLookup(_ entries: [IndexNoteEntry]) -> [String: IndexNoteEntry] {
        var lookup: [String: IndexNoteEntry] = [:]
        for entry in entries {
            let titleKey = normalizedLinkKey(entry.title)
            if !titleKey.isEmpty {
                lookup[titleKey] = entry
            }
            let pathKey = normalizedLinkKey(titleFromPath(entry.path))
            if !pathKey.isEmpty {
                lookup[pathKey] = entry
            }
        }
        return lookup
    }

    private func collectLinks(from entry: IndexNoteEntry, snippetByPath: [String: String]) -> [String] {
        if let links = entry.links, !links.isEmpty {
            return links
        }
        if let snippet = snippetByPath[entry.path] {
            let extracted = extractWikiLinks(from: snippet, limit: 6)
            if !extracted.isEmpty {
                return extracted
            }
        }
        let body = loadNoteBody(path: entry.path, maxCharacters: 1200)
        return extractWikiLinks(from: body ?? "", limit: 6)
    }

    private func extractWikiLinks(from text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var results: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let open = text.range(of: "[[", range: searchRange) {
            guard let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) else {
                break
            }
            let raw = String(text[open.upperBound..<close.lowerBound])
            if !raw.isEmpty {
                results.append(raw)
                if results.count >= limit {
                    break
                }
            }
            searchRange = close.upperBound..<text.endIndex
        }
        return results
    }

    private func normalizedLinkKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var normalized = trimmed
        if normalized.hasPrefix("[[") && normalized.hasSuffix("]]") {
            normalized = String(normalized.dropFirst(2).dropLast(2))
        }
        if let pipeIndex = normalized.firstIndex(of: "|") {
            normalized = String(normalized[..<pipeIndex])
        }
        if let hashIndex = normalized.firstIndex(of: "#") {
            normalized = String(normalized[..<hashIndex])
        }
        normalized = (normalized as NSString).deletingPathExtension
        normalized = (normalized as NSString).lastPathComponent
        normalized = normalized
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return normalized
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallbackEntry(path: String, title: String?) -> IndexNoteEntry {
        let resolvedTitle = (title?.isEmpty == false) ? title! : titleFromPath(path)
        return IndexNoteEntry(
            path: path,
            title: resolvedTitle,
            summary: nil,
            tags: nil,
            links: nil,
            updatedAt: nil
        )
    }

    private func titleFromPath(_ path: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? path : base
    }

    private func makeExcerpt(from text: String?, maxCharacters: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxCharacters {
            return text
        }
        let endIndex = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<endIndex])
    }

    private func loadNoteBody(path: String, maxCharacters: Int) -> String? {
        guard let url = try? VaultScanStore.url(for: path),
              let contents = try? VaultFileStore.readText(from: url) else {
            return nil
        }
        if contents.count > maxCharacters {
            let endIndex = contents.index(contents.startIndex, offsetBy: maxCharacters)
            return String(contents[..<endIndex])
        }
        return contents
    }

    private func loadNoteBodyFull(path: String) -> String? {
        guard let url = try? VaultScanStore.url(for: path),
              let contents = try? VaultFileStore.readText(from: url) else {
            return nil
        }
        return contents
    }

    private func removeSearchStoreFiles(rootURL: URL) {
        let directory = rootURL.appendingPathComponent("_system")
        let candidates = [
            directory.appendingPathComponent("search.sqlite"),
            directory.appendingPathComponent("search.sqlite-wal"),
            directory.appendingPathComponent("search.sqlite-shm")
        ]
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func withSQLite<T>(_ work: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        sqliteQueue.sync {
            result = Result { try work() }
        }
        return try result.get()
    }

    private func createSearchTable(_ db: OpaquePointer?) throws {
        let sql = """
        CREATE VIRTUAL TABLE IF NOT EXISTS notes USING fts5(
          path UNINDEXED,
          title,
          body,
          summary,
          tags,
          links,
          tokenize = 'porter'
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw VaultIndexError.sqliteStepFailed
        }
    }

    private func deleteEntry(_ db: OpaquePointer?, path: String) throws {
        let sql = "DELETE FROM notes WHERE path = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VaultIndexError.sqlitePrepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: path)
        if sqlite3_step(statement) != SQLITE_DONE {
            throw VaultIndexError.sqliteStepFailed
        }
    }

    private func insertEntry(_ db: OpaquePointer?, entry: IndexNoteEntry, body: String) throws {
        let sql = """
        INSERT INTO notes (path, title, body, summary, tags, links)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VaultIndexError.sqlitePrepareFailed
        }
        defer { sqlite3_finalize(statement) }
        let tags = (entry.tags ?? []).joined(separator: " ")
        let links = (entry.links ?? []).joined(separator: " ")
        bindText(statement, index: 1, value: entry.path)
        bindText(statement, index: 2, value: entry.title)
        bindText(statement, index: 3, value: body)
        bindText(statement, index: 4, value: entry.summary ?? "")
        bindText(statement, index: 5, value: tags)
        bindText(statement, index: 6, value: links)
        if sqlite3_step(statement) != SQLITE_DONE {
            throw VaultIndexError.sqliteStepFailed
        }
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func updateIndexEntity(
        context: NSManagedObjectContext?,
        notesCount: Int,
        updatedAt: Date
    ) async {
        guard let context else { return }
        await context.perform {
            let request = IndexEntity.fetchRequest()
            request.fetchLimit = 1
            let indexEntity: IndexEntity
            if let existing = try? context.fetch(request).first {
                indexEntity = existing
            } else {
                indexEntity = IndexEntity(context: context)
                indexEntity.id = UUID()
                indexEntity.indexPath = "_system/INDEX.json"
                indexEntity.structurePath = "_system/STRUCTURE.txt"
                indexEntity.lastRebuildAt = updatedAt
            }
            indexEntity.notesCount = Int32(notesCount)
            indexEntity.updatedAt = updatedAt
            try? context.save()
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultIndexError.vaultRootUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }
}
