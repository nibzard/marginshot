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

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime]
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
            let noteBody = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
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
        try data.write(to: indexURL, options: .atomic)
        return snapshot.notes.count
    }

    private func loadIndexSnapshot(from url: URL) -> IndexSnapshot {
        guard let data = try? Data(contentsOf: url) else {
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
        try contents.write(to: structureURL, atomically: true, encoding: .utf8)
    }

    private func updateSearchStore(entry: IndexNoteEntry, body: String, rootURL: URL) throws {
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
