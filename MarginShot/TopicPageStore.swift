import CoreData
import Foundation

enum TopicPageStore {
    private struct TopicAccumulator {
        var title: String
        var notes: [TopicNote]
        var seenPaths: Set<String>
    }

    private struct TopicNote {
        let path: String
        let title: String
    }

    private struct TopicPage {
        let key: String
        let title: String
        let notes: [TopicNote]
    }

    private static let topicsFolder = "_topics"
    private static let autoMarker = "<!-- marginshot:topic-page -->"
    private static let fileManager = FileManager.default
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func refreshIfEnabled(context: NSManagedObjectContext?) async {
        guard OrganizationPreferences().topicPagesEnabled else { return }
        do {
            let rootURL = try vaultRootURL()
            let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
            guard let data = try? VaultFileStore.readData(from: indexURL),
                  let snapshot = try? JSONDecoder().decode(IndexSnapshot.self, from: data) else {
                return
            }
            let pages = buildTopics(from: snapshot.notes)
            let expectedFiles = Set(pages.map { topicFileName(for: $0.title) })
            try await pruneAutoTopicPages(expectedFiles: expectedFiles, rootURL: rootURL, context: context)
            let updatedAt = Date()
            for page in pages {
                try await writeTopicPage(page, rootURL: rootURL, updatedAt: updatedAt, context: context)
            }
        } catch {
            print("Topic page refresh failed: \(error)")
        }
    }

    private static func buildTopics(from entries: [IndexNoteEntry]) -> [TopicPage] {
        var accumulators: [String: TopicAccumulator] = [:]
        for entry in entries {
            guard shouldInclude(path: entry.path) else { continue }
            let noteTitle = resolvedNoteTitle(path: entry.path, title: entry.title)
            let note = TopicNote(path: entry.path, title: noteTitle)
            for tag in entry.tags ?? [] {
                let cleaned = cleanTag(tag)
                let key = normalizedTagKey(cleaned)
                guard !key.isEmpty else { continue }
                var accumulator = accumulators[key] ?? TopicAccumulator(
                    title: cleaned.isEmpty ? "Untitled" : cleaned,
                    notes: [],
                    seenPaths: []
                )
                guard accumulator.seenPaths.insert(entry.path).inserted else { continue }
                accumulator.notes.append(note)
                accumulators[key] = accumulator
            }
        }

        let pages = accumulators.map { key, value -> TopicPage in
            let sortedNotes = value.notes.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return TopicPage(key: key, title: value.title, notes: sortedNotes)
        }

        return pages.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func writeTopicPage(
        _ page: TopicPage,
        rootURL: URL,
        updatedAt: Date,
        context: NSManagedObjectContext?
    ) async throws {
        let fileName = topicFileName(for: page.title)
        let relativePath = "\(topicsFolder)/\(fileName)"
        let url = rootURL.appendingPathComponent(relativePath)

        guard shouldOverwrite(at: url) else { return }

        let content = buildTopicPageContent(page: page, updatedAt: updatedAt)
        try writeAtomically(text: content, to: url)
        let noteMeta = NoteMeta(
            title: page.title,
            summary: "Topic page for \(page.title).",
            tags: ["topic"],
            links: nil
        )
        await VaultIndexStore.shared.updateAfterNoteWrite(
            notePath: relativePath,
            noteTitle: page.title,
            noteMeta: noteMeta,
            context: context
        )
    }

    private static func pruneAutoTopicPages(
        expectedFiles: Set<String>,
        rootURL: URL,
        context: NSManagedObjectContext?
    ) async throws {
        let topicsURL = rootURL.appendingPathComponent(topicsFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: topicsURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let items = try fileManager.contentsOfDirectory(
            at: topicsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for url in items {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let fileName = url.lastPathComponent
            guard !expectedFiles.contains(fileName) else { continue }
            guard let contents = try? VaultFileStore.readText(from: url),
                  contents.contains(autoMarker) else { continue }
            try fileManager.removeItem(at: url)
            let relativePath = "\(topicsFolder)/\(fileName)"
            await VaultIndexStore.shared.removeNote(path: relativePath, context: context)
        }
    }

    private static func buildTopicPageContent(page: TopicPage, updatedAt: Date) -> String {
        var content = "\(autoMarker)\n"
        content += "# Topic: \(page.title)\n"
        content += "Updated: \(isoFormatter.string(from: updatedAt))\n\n"
        content += "## Notes\n"
        for note in page.notes {
            let link = relativeLink(path: note.path)
            content += "- [\(note.title)](\(link))\n"
        }
        return content
    }

    private static func shouldOverwrite(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        guard let existing = try? VaultFileStore.readText(from: url) else { return true }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        return existing.contains(autoMarker)
    }

    private static func shouldInclude(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("_system/") || trimmed.hasPrefix("\(topicsFolder)/") || trimmed.hasPrefix("scans/") {
            return false
        }
        let components = trimmed.split(separator: "/")
        guard let first = components.first else { return false }
        let root = String(first)
        if root == VaultFolder.tasks.simpleName || root == VaultFolder.tasks.johnnyDecimalName {
            return false
        }
        return (trimmed as NSString).pathExtension.lowercased() == "md"
    }

    private static func cleanTag(_ tag: String) -> String {
        var trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTagKey(_ tag: String) -> String {
        tag
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func topicFileName(for title: String) -> String {
        let base = sanitizeFileName(title)
        let resolved = base.isEmpty ? "topic" : base
        return "\(resolved).md"
    }

    private static func sanitizeFileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let mapped = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let raw = String(mapped)
        let dashed = raw.replacingOccurrences(of: " ", with: "-")
        var collapsed = dashed
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ").union(.whitespacesAndNewlines))
        return trimmed
    }

    private static func relativeLink(path: String) -> String {
        let relativePath = "../\(path)"
        return relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
    }

    private static func resolvedNoteTitle(path: String, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? titleFromPath(path) : trimmed
    }

    private static func titleFromPath(_ path: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        let base = (fileName as NSString).deletingPathExtension
        if !base.isEmpty {
            return base.replacingOccurrences(of: "-", with: " ")
        }
        return path
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultWriterError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    private static func writeAtomically(text: String, to url: URL) throws {
        try VaultFileStore.writeText(text, to: url)
    }
}
