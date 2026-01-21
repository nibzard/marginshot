import BackgroundTasks
import CoreData
import Foundation
import Network
import UIKit

struct ProcessingPreferences {
    var autoProcessInbox: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "processingAutoProcessInbox") == nil {
            return true
        }
        return defaults.bool(forKey: "processingAutoProcessInbox")
    }

    var requiresWiFi: Bool {
        UserDefaults.standard.bool(forKey: "processingWiFiOnly")
    }

    var requiresExternalPower: Bool {
        UserDefaults.standard.bool(forKey: "processingRequiresCharging")
    }

    var qualityMode: ProcessingQualityMode {
        ProcessingQualityMode.load()
    }

    var allowsImageUploads: Bool {
        UserDefaults.standard.object(forKey: "privacySendImagesToLLM") as? Bool ?? true
    }
}

struct ScanSnapshot {
    let id: UUID
    let batchId: UUID?
    let createdAt: Date
    let status: ScanStatus
    let imagePath: String
    let processedPath: String?
    let transcriptJSON: String?
    let structuredJSON: String?
    let ocrText: String?
    let structuredMarkdown: String?
}

struct VaultWriterInput {
    let scanId: UUID
    let batchId: UUID?
    let capturedAt: Date
    let imagePath: String
    let processedImagePath: String?
    let transcript: TranscriptionPayload
    let transcriptJSON: String?
    let structured: StructurePayload
    let structuredJSON: String?
}

struct VaultWriteResult {
    let notePath: String
    let noteTitle: String
    let metadataPath: String
    let noteMeta: NoteMeta
    let createdEntities: [EntityPage]
}

struct EntityPage: Equatable {
    let path: String
    let title: String
}

struct ScanMetadata: Codable {
    let scanId: String
    let batchId: String?
    let capturedAt: String
    let imagePath: String
    let processedImagePath: String?
    let notePath: String
    let noteTitle: String
    let transcript: TranscriptionPayload
    let structured: StructurePayload
    let transcriptJSON: String?
    let structuredJSON: String?
}

enum VaultWriterError: Error {
    case documentsDirectoryUnavailable
    case invalidPayload
}

enum VaultWriter {
    private static let fileManager = FileManager.default
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func apply(input: VaultWriterInput, userDefaults: UserDefaults = .standard) throws -> VaultWriteResult {
        let rootURL = try vaultRootURL()
        let preferences = OrganizationPreferences(userDefaults: userDefaults)
        let resolved = resolveWikiLinks(for: input, linkingEnabled: preferences.linkingEnabled)
        let style = preferences.style
        let normalizedStructured = try normalizeClassification(resolved.structured, style: style)
        let folder = normalizedStructured.classification.folder
        let noteResult = try writeNote(
            input: input,
            structured: normalizedStructured,
            rootURL: rootURL,
            folder: folder,
            style: style,
            userDefaults: userDefaults
        )
        let metadataPath = VaultScanStore.metadataPath(for: input.processedImagePath ?? input.imagePath)
        let metadataURL = rootURL.appendingPathComponent(metadataPath)
        let metadata = ScanMetadata(
            scanId: input.scanId.uuidString,
            batchId: input.batchId?.uuidString,
            capturedAt: isoFormatter.string(from: input.capturedAt),
            imagePath: input.imagePath,
            processedImagePath: input.processedImagePath,
            notePath: noteResult.path,
            noteTitle: noteResult.title,
            transcript: input.transcript,
            structured: normalizedStructured,
            transcriptJSON: input.transcriptJSON,
            structuredJSON: input.structuredJSON
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)
        try writeAtomically(data: metadataData, to: metadataURL)
        let createdEntities: [EntityPage]
        if preferences.linkingEnabled {
            createdEntities = try ensureEntityPages(links: resolved.linkTitles, rootURL: rootURL, style: style, userDefaults: userDefaults)
        } else {
            createdEntities = []
        }
        return VaultWriteResult(
            notePath: noteResult.path,
            noteTitle: noteResult.title,
            metadataPath: metadataPath,
            noteMeta: normalizedStructured.noteMeta,
            createdEntities: createdEntities
        )
    }

    private static func writeNote(
        input: VaultWriterInput,
        structured: StructurePayload,
        rootURL: URL,
        folder: String,
        style: OrganizationStyle,
        userDefaults: UserDefaults = .standard
    ) throws -> (path: String, title: String) {
        let directoryURL = rootURL.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        if folder == dailyFolderName(for: style) {
            let dateString = dateFormatter.string(from: input.capturedAt)
            let fileName = "\(dateString).md"
            let notePath = "\(folder)/\(fileName)"
            let noteURL = rootURL.appendingPathComponent(notePath)
            let entry = buildDailyEntry(input: input, structured: structured)
            let updated = try appendDailyEntry(existingAt: noteURL, dateString: dateString, entry: entry, userDefaults: userDefaults)
            try writeAtomically(text: updated, to: noteURL, userDefaults: userDefaults)
            return (notePath, dateString)
        }

        let baseName = sanitizeFileName(structured.noteMeta.title)
        let fileName = uniqueFileName(baseName: baseName, in: directoryURL)
        let notePath = "\(folder)/\(fileName)"
        let noteURL = rootURL.appendingPathComponent(notePath)
        let content = buildNoteContent(input: input, structured: structured)
        try writeAtomically(text: content, to: noteURL, userDefaults: userDefaults)
        return (notePath, structured.noteMeta.title)
    }

    private static func buildDailyEntry(input: VaultWriterInput, structured: StructurePayload) -> String {
        let title = structured.noteMeta.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryTitle = title.isEmpty ? "Scan Notes" : title
        let timestamp = timeFormatter.string(from: input.capturedAt)
        var entry = "## \(entryTitle)\n"
        entry += "Captured: \(timestamp)\n"
        if let batchId = input.batchId?.uuidString {
            entry += "Batch: \(batchId)\n"
        }
        entry += "Scan: \(input.scanId.uuidString)\n\n"
        entry += normalizedMarkdown(structured.markdown)
        if shouldAppendRawTranscript(to: structured.markdown) {
            entry += "\n\n### Raw transcription\n"
            entry += input.transcript.rawTranscript
        }
        return entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendDailyEntry(existingAt url: URL, dateString: String, entry: String, userDefaults: UserDefaults = .standard) throws -> String {
        let existing = (try? VaultFileStore.readText(from: url, userDefaults: userDefaults)) ?? ""
        if existing.isEmpty {
            return "# \(dateString)\n\n\(entry)\n"
        }

        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSeparator = trimmed.contains("\n## ")
        var updated = existing
        if needsSeparator {
            updated += "\n\n---\n\n"
        } else if !updated.hasSuffix("\n\n") {
            updated += "\n\n"
        }
        updated += entry
        if !updated.hasSuffix("\n") {
            updated += "\n"
        }
        return updated
    }

    private static func buildNoteContent(input: VaultWriterInput, structured: StructurePayload) -> String {
        var content = normalizedMarkdown(structured.markdown)
        if shouldAppendRawTranscript(to: structured.markdown) {
            content += "\n\n## Raw transcription\n"
            content += input.transcript.rawTranscript
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func normalizedMarkdown(_ markdown: String) -> String {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldAppendRawTranscript(to markdown: String) -> Bool {
        let lowercased = markdown.lowercased()
        return !lowercased.contains("raw transcription") && !lowercased.contains("raw transcript")
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
        return trimmed.isEmpty ? "note" : trimmed
    }

    private static func uniqueFileName(baseName: String, in directory: URL) -> String {
        var candidate = "\(baseName).md"
        var index = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(index).md"
            index += 1
        }
        return candidate
    }

    private struct ResolvedNoteLinks {
        let structured: StructurePayload
        let linkTitles: [String]
    }

    private static func resolveWikiLinks(for input: VaultWriterInput, linkingEnabled: Bool) -> ResolvedNoteLinks {
        let baseMarkdown = normalizedMarkdown(input.structured.markdown)
        guard linkingEnabled else {
            let updatedNoteMeta = NoteMeta(
                title: input.structured.noteMeta.title,
                summary: input.structured.noteMeta.summary,
                tags: input.structured.noteMeta.tags,
                links: nil
            )
            let updatedStructured = StructurePayload(
                markdown: baseMarkdown,
                noteMeta: updatedNoteMeta,
                classification: input.structured.classification,
                warnings: input.structured.warnings
            )
            return ResolvedNoteLinks(structured: updatedStructured, linkTitles: [])
        }
        let extracted = extractWikiLinks(from: baseMarkdown, limit: 24)
        let merged = mergeLinkTitles(primary: input.structured.noteMeta.links, secondary: extracted)
        let updatedMarkdown = appendMissingLinks(to: baseMarkdown, links: merged)
        let updatedLinks = merged.isEmpty ? nil : merged
        let updatedNoteMeta = NoteMeta(
            title: input.structured.noteMeta.title,
            summary: input.structured.noteMeta.summary,
            tags: input.structured.noteMeta.tags,
            links: updatedLinks
        )
        let updatedStructured = StructurePayload(
            markdown: updatedMarkdown,
            noteMeta: updatedNoteMeta,
            classification: input.structured.classification,
            warnings: input.structured.warnings
        )
        return ResolvedNoteLinks(structured: updatedStructured, linkTitles: merged)
    }

    private static func normalizeClassification(
        _ structured: StructurePayload,
        style: OrganizationStyle
    ) throws -> StructurePayload {
        guard let normalizedFolder = VaultFolder.resolvedFolderName(
            from: structured.classification.folder,
            style: style
        ) else {
            throw VaultWriterError.invalidPayload
        }
        if normalizedFolder == structured.classification.folder {
            return structured
        }
        let updatedClassification = Classification(
            folder: normalizedFolder,
            reason: structured.classification.reason
        )
        return StructurePayload(
            markdown: structured.markdown,
            noteMeta: structured.noteMeta,
            classification: updatedClassification,
            warnings: structured.warnings
        )
    }

    private static func mergeLinkTitles(primary: [String]?, secondary: [String]) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        let allLinks = (primary ?? []) + secondary
        for link in allLinks {
            let title = resolvedLinkTitle(link)
            let key = normalizedLinkKey(title)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            results.append(title)
        }
        return results
    }

    private static func appendMissingLinks(to markdown: String, links: [String]) -> String {
        guard !links.isEmpty else { return markdown }
        let existingKeys = Set(extractWikiLinks(from: markdown, limit: 40).map { normalizedLinkKey($0) })
        let missing = links.filter { !existingKeys.contains(normalizedLinkKey($0)) }
        guard !missing.isEmpty else { return markdown }
        let linkList = missing.map { "- [[\($0)]]" }.joined(separator: "\n")
        var updated = markdown
        if !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += "\n## Links\n" + linkList
        return updated
    }

    private static func extractWikiLinks(from text: String, limit: Int) -> [String] {
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

    private static func resolvedLinkTitle(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
            trimmed = String(trimmed.dropFirst(2).dropLast(2))
        }
        if let pipeIndex = trimmed.firstIndex(of: "|") {
            trimmed = String(trimmed[..<pipeIndex])
        }
        if let hashIndex = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<hashIndex])
        }
        trimmed = (trimmed as NSString).deletingPathExtension
        trimmed = (trimmed as NSString).lastPathComponent
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLinkKey(_ value: String) -> String {
        let resolved = resolvedLinkTitle(value)
        guard !resolved.isEmpty else { return "" }
        let normalized = resolved
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private static func ensureEntityPages(
        links: [String],
        rootURL: URL,
        style: OrganizationStyle,
        userDefaults: UserDefaults = .standard
    ) throws -> [EntityPage] {
        guard !links.isEmpty else { return [] }
        let existingKeys = loadExistingLinkKeys(rootURL: rootURL, userDefaults: userDefaults)
        var seenKeys = existingKeys
        var created: [EntityPage] = []

        let entityFolder = entityFolderName(for: style)
        let directoryURL = rootURL.appendingPathComponent(entityFolder, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        for link in links {
            let title = resolvedLinkTitle(link)
            let key = normalizedLinkKey(title)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            let baseName = sanitizeFileName(title)
            guard !baseName.isEmpty else { continue }
            let fileName = "\(baseName).md"
            let targetURL = directoryURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: targetURL.path) {
                continue
            }
            let content = buildEntityPageContent(title: title)
            try writeAtomically(text: content, to: targetURL, userDefaults: userDefaults)
            let path = "\(entityFolder)/\(fileName)"
            created.append(EntityPage(path: path, title: title))
        }
        return created
    }

    private static func loadExistingLinkKeys(rootURL: URL, userDefaults: UserDefaults = .standard) -> Set<String> {
        let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
        guard let data = try? VaultFileStore.readData(from: indexURL, userDefaults: userDefaults),
              let snapshot = try? JSONDecoder().decode(IndexSnapshot.self, from: data) else {
            return []
        }
        var keys = Set<String>()
        for entry in snapshot.notes {
            let titleKey = normalizedLinkKey(entry.title)
            if !titleKey.isEmpty {
                keys.insert(titleKey)
            }
            let pathKey = normalizedLinkKey(titleFromPath(entry.path))
            if !pathKey.isEmpty {
                keys.insert(pathKey)
            }
        }
        return keys
    }

    private static func titleFromPath(_ path: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? path : base
    }

    private static func buildEntityPageContent(title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmed.isEmpty ? "Untitled" : trimmed
        return """
        # \(displayTitle)

        ## Notes
        - TODO: Add details.
        """
    }

    private static func dailyFolderName(for style: OrganizationStyle) -> String {
        VaultFolder.daily.folderName(style: style)
    }

    private static func entityFolderName(for style: OrganizationStyle) -> String {
        VaultFolder.projects.folderName(style: style)
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultWriterError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    private static func writeAtomically(text: String, to url: URL, userDefaults: UserDefaults = .standard) throws {
        try VaultFileStore.writeText(text, to: url, userDefaults: userDefaults)
    }

    private static func writeAtomically(data: Data, to url: URL) throws {
        try VaultFileStore.writeData(data, to: url)
    }
}

enum TaskConsolidatorError: Error {
    case documentsDirectoryUnavailable
}

enum TaskConsolidator {
    private struct NoteEntry {
        let path: String
        let title: String
    }

    private struct TaskSource {
        let path: String
        let title: String
        let tasks: [String]
    }

    private static let tasksFileName = "Tasks.md"
    private static var skipRoots: Set<String> {
        Set([
            "_system",
            "scans",
            "_topics",
            VaultFolder.tasks.simpleName,
            VaultFolder.tasks.johnnyDecimalName
        ])
    }
    private static let fileManager = FileManager.default
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let checkboxRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: #"^\s*[-*]\s+\[( |x|X)\]\s+(.*)$"#, options: [])
    }()

    static func refreshIfEnabled(context: NSManagedObjectContext?) async {
        guard UserDefaults.standard.bool(forKey: "organizationTaskExtractionEnabled") else { return }
        do {
            let rootURL = try vaultRootURL()
            let entries = loadNoteEntries(rootURL: rootURL)
            let sources = entries.compactMap { entry -> TaskSource? in
                let noteURL = rootURL.appendingPathComponent(entry.path)
                guard let markdown = try? VaultFileStore.readText(from: noteURL) else { return nil }
                let tasks = extractOpenTasks(from: markdown)
                guard !tasks.isEmpty else { return nil }
                return TaskSource(path: entry.path, title: entry.title, tasks: tasks)
            }
            let sortedSources = sources.sorted { $0.path < $1.path }
            let content = buildTasksMarkdown(sources: sortedSources, updatedAt: Date())
            let tasksPath = "\(tasksFolderName())/\(tasksFileName)"
            let tasksURL = rootURL.appendingPathComponent(tasksPath)
            try writeAtomically(text: content, to: tasksURL)
            let noteMeta = NoteMeta(
                title: "Tasks",
                summary: "Consolidated open tasks.",
                tags: ["tasks"],
                links: nil
            )
            await VaultIndexStore.shared.updateAfterNoteWrite(
                notePath: tasksPath,
                noteTitle: "Tasks",
                noteMeta: noteMeta,
                context: context
            )
        } catch {
            print("Task consolidation failed: \(error)")
        }
    }

    private static func tasksFolderName() -> String {
        VaultFolder.tasks.folderName(style: OrganizationPreferences().style)
    }

    private static func loadNoteEntries(rootURL: URL) -> [NoteEntry] {
        let indexURL = rootURL.appendingPathComponent("_system/INDEX.json")
        if let data = try? VaultFileStore.readData(from: indexURL),
           let snapshot = try? JSONDecoder().decode(IndexSnapshot.self, from: data) {
            let entries = snapshot.notes.compactMap { note -> NoteEntry? in
                guard shouldInclude(path: note.path) else { return nil }
                let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return NoteEntry(path: note.path, title: title.isEmpty ? titleFromPath(note.path) : title)
            }
            return entries.sorted { $0.path < $1.path }
        }
        return enumerateNoteEntries(rootURL: rootURL).sorted { $0.path < $1.path }
    }

    private static func enumerateNoteEntries(rootURL: URL) -> [NoteEntry] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [NoteEntry] = []
        for case let url as URL in enumerator {
            let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let components = relativePath.split(separator: "/")
            guard let first = components.first else { continue }
            if skipRoots.contains(String(first)) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }
            guard shouldInclude(path: relativePath) else { continue }
            let title = titleFromPath(relativePath)
            entries.append(NoteEntry(path: relativePath, title: title))
        }
        return entries
    }

    private static func shouldInclude(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let components = trimmed.split(separator: "/")
        guard let first = components.first, !skipRoots.contains(String(first)) else { return false }
        return (trimmed as NSString).pathExtension.lowercased() == "md"
    }

    private static func extractOpenTasks(from markdown: String) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        var skipRemaining = false

        for lineSub in markdown.split(whereSeparator: \.isNewline) {
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                let lower = trimmed.lowercased()
                if lower.contains("raw transcription") || lower.contains("raw transcript") {
                    skipRemaining = true
                    continue
                }
            }
            if skipRemaining { continue }
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = checkboxRegex.firstMatch(in: line, range: range) else { continue }
            guard let stateRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line) else { continue }
            let state = String(line[stateRange])
            if state.lowercased() == "x" { continue }
            let task = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            let key = normalizedTaskKey(task)
            guard seen.insert(key).inserted else { continue }
            results.append(task)
        }

        return results
    }

    private static func normalizedTaskKey(_ task: String) -> String {
        task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildTasksMarkdown(sources: [TaskSource], updatedAt: Date) -> String {
        var content = "# Tasks\n"
        content += "Updated: \(isoFormatter.string(from: updatedAt))\n\n"
        if sources.isEmpty {
            content += "No open tasks found.\n"
            return content
        }

        for source in sources {
            content += "## \(source.title)\n"
            let relativePath = "../\(source.path)"
            let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
            content += "Source: [\(source.path)](\(encodedPath))\n"
            for task in source.tasks {
                content += "- [ ] \(task)\n"
            }
            content += "\n"
        }
        return content
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
            throw TaskConsolidatorError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    private static func writeAtomically(text: String, to url: URL) throws {
        try VaultFileStore.writeText(text, to: url)
    }
}

enum VaultFileAction: String, Codable {
    case create
    case update
    case delete
}

struct VaultFileOperation: Codable, Equatable {
    let action: VaultFileAction
    let path: String
    let content: String?
    let noteMeta: NoteMeta?
}

struct VaultApplySummary: Equatable {
    let createdOrUpdated: [String]
    let deleted: [String]
}

enum VaultApplyError: Error, LocalizedError {
    case vaultUnavailable
    case emptyOperations
    case invalidOperation(String)
    case applyFailed(String)

    var errorDescription: String? {
        switch self {
        case .vaultUnavailable:
            return "Vault location is unavailable."
        case .emptyOperations:
            return "No changes to apply."
        case .invalidOperation(let message):
            return message
        case .applyFailed(let message):
            return "Apply failed. \(message)"
        }
    }
}

enum VaultApplyService {
    private static let fileManager = FileManager.default
    private static let allowedExtensions: Set<String> = ["md"]
    private static let disallowedRoots: Set<String> = ["_system", "scans"]

    private struct PreparedOperation {
        let operation: VaultFileOperation
        let path: String
        let targetURL: URL
        let stagedURL: URL?
        let backupURL: URL?
    }

    static func apply(_ operations: [VaultFileOperation], userDefaults: UserDefaults = .standard) async throws -> VaultApplySummary {
        let sanitized = try sanitizeOperations(operations)
        guard !sanitized.isEmpty else { throw VaultApplyError.emptyOperations }
        let rootURL = try vaultRootURL()

        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("marginshot-apply-\(UUID().uuidString)", isDirectory: true)
        let stagedRootURL = stagingURL.appendingPathComponent("staged", isDirectory: true)
        let backupRootURL = stagingURL.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: stagedRootURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: backupRootURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: stagingURL) }

        var prepared: [PreparedOperation] = []
        var seen = Set<String>()

        for operation in sanitized {
            guard seen.insert(operation.path).inserted else {
                throw VaultApplyError.invalidOperation("Duplicate path: \(operation.path)")
            }

            let targetURL = rootURL.appendingPathComponent(operation.path)
            try ensureWithinVault(targetURL, rootURL)
            let exists = fileManager.fileExists(atPath: targetURL.path)

            switch operation.action {
            case .create:
                if exists {
                    throw VaultApplyError.invalidOperation("File already exists: \(operation.path)")
                }
            case .update:
                if !exists {
                    throw VaultApplyError.invalidOperation("File not found: \(operation.path)")
                }
            case .delete:
                if !exists {
                    throw VaultApplyError.invalidOperation("File not found: \(operation.path)")
                }
            }

            var backupURL: URL?
            if exists {
                let backup = backupRootURL.appendingPathComponent(operation.path)
                try fileManager.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try fileManager.copyItem(at: targetURL, to: backup)
                backupURL = backup
            }

            var stagedURL: URL?
            if operation.action != .delete {
                guard let content = operation.content,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VaultApplyError.invalidOperation("Missing content for \(operation.path)")
                }
                let staged = stagedRootURL.appendingPathComponent(operation.path)
                try fileManager.createDirectory(
                    at: staged.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try Data(content.utf8).write(to: staged, options: .atomic)
                stagedURL = staged
            }

            prepared.append(
                PreparedOperation(
                    operation: operation,
                    path: operation.path,
                    targetURL: targetURL,
                    stagedURL: stagedURL,
                    backupURL: backupURL
                )
            )
        }

        var applied: [PreparedOperation] = []
        do {
            for item in prepared {
                switch item.operation.action {
                case .delete:
                    try fileManager.removeItem(at: item.targetURL)
                case .create, .update:
                    guard let stagedURL = item.stagedURL else {
                        throw VaultApplyError.invalidOperation("Missing content for \(item.path)")
                    }
                    try fileManager.createDirectory(
                        at: item.targetURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    let data = try Data(contentsOf: stagedURL)
                    try VaultFileStore.writeData(data, to: item.targetURL, userDefaults: userDefaults)
                }
                applied.append(item)
            }
        } catch {
            rollback(applied)
            throw VaultApplyError.applyFailed(error.localizedDescription)
        }

        await updateIndex(for: prepared, userDefaults: userDefaults)
        return VaultApplySummary(
            createdOrUpdated: prepared.filter { $0.operation.action != .delete }.map { $0.path },
            deleted: prepared.filter { $0.operation.action == .delete }.map { $0.path }
        )
    }

    private static func sanitizeOperations(_ operations: [VaultFileOperation]) throws -> [VaultFileOperation] {
        try operations.map { operation in
            let normalized = try normalizePath(operation.path)
            return VaultFileOperation(
                action: operation.action,
                path: normalized,
                content: operation.content,
                noteMeta: operation.noteMeta
            )
        }
    }

    private static func normalizePath(_ path: String) throws -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultApplyError.invalidOperation("Missing file path.")
        }
        if trimmed.hasPrefix("vault/") {
            trimmed.removeFirst("vault/".count)
        }
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else {
            throw VaultApplyError.invalidOperation("Missing file path.")
        }
        let components = trimmed.split(separator: "/")
        if components.contains(where: { $0 == "." || $0 == ".." }) {
            throw VaultApplyError.invalidOperation("Invalid path: \(trimmed)")
        }
        if let first = components.first, disallowedRoots.contains(String(first)) {
            throw VaultApplyError.invalidOperation("Path not allowed: \(trimmed)")
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw VaultApplyError.invalidOperation("Only .md files can be modified.")
        }
        let style = OrganizationPreferences().style
        return VaultFolder.normalizeTopLevelPath(trimmed, style: style)
    }

    private static func ensureWithinVault(_ targetURL: URL, _ rootURL: URL) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw VaultApplyError.invalidOperation("Path escapes vault root.")
        }
    }

    private static func rollback(_ applied: [PreparedOperation]) {
        for item in applied.reversed() {
            if let backupURL = item.backupURL {
                try? fileManager.createDirectory(
                    at: item.targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                if fileManager.fileExists(atPath: item.targetURL.path) {
                    _ = try? fileManager.replaceItemAt(item.targetURL, withItemAt: backupURL)
                } else {
                    try? fileManager.copyItem(at: backupURL, to: item.targetURL)
                }
            } else {
                try? fileManager.removeItem(at: item.targetURL)
            }
        }
    }

    private static func updateIndex(for operations: [PreparedOperation], userDefaults: UserDefaults = .standard) async {
        for item in operations {
            switch item.operation.action {
            case .delete:
                await VaultIndexStore.shared.removeNote(path: item.path, context: nil)
            case .create, .update:
                guard let content = item.operation.content else { continue }
                let meta = resolvedNoteMeta(for: item.operation, content: content)
                await VaultIndexStore.shared.updateAfterNoteWrite(
                    notePath: item.path,
                    noteTitle: meta.title,
                    noteMeta: meta,
                    context: nil
                )
            }
        }
        await TopicPageStore.refreshIfEnabled(context: nil)
        await TaskConsolidator.refreshIfEnabled(context: nil)
    }

    private static func resolvedNoteMeta(for operation: VaultFileOperation, content: String) -> NoteMeta {
        let trimmedTitle = operation.noteMeta?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? inferredTitle(from: content, path: operation.path) : trimmedTitle
        return NoteMeta(
            title: title,
            summary: operation.noteMeta?.summary,
            tags: operation.noteMeta?.tags,
            links: operation.noteMeta?.links
        )
    }

    private static func inferredTitle(from content: String, path: String) -> String {
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                let title = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }
        }
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if !base.isEmpty {
            return base.replacingOccurrences(of: "-", with: " ")
        }
        return "Untitled"
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultApplyError.vaultUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }
}

final class ProcessingQueue {
    static let shared = ProcessingQueue()

    private let persistenceController: PersistenceController
    private var taskIdentifier: String {
        Bundle.main.bundleIdentifier.map { "\($0).processing" } ?? "processing"
    }
    private let processingLock = NSLock()
    private var isProcessing = false

    private var preferences: ProcessingPreferences {
        ProcessingPreferences()
    }

    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    func registerBackgroundTasks() {
        guard supportsBackgroundTasks else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
            self?.handleBackgroundTask(task)
        }
    }

    func enqueuePendingProcessing() {
        guard preferences.autoProcessInbox else { return }
        scheduleBackgroundProcessing()
        processPendingBatchesIfNeeded()
    }

    func enqueueOpenBatches() {
        guard preferences.autoProcessInbox else { return }
        let context = persistenceController.container.newBackgroundContext()
        let openBatchIDs: [NSManagedObjectID] = context.performAndWait {
            let request = BatchEntity.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", BatchStatus.open.rawValue)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            do {
                let openBatches = try context.fetch(request)
                guard !openBatches.isEmpty else { return [] }
                for batch in openBatches {
                    batch.status = BatchStatus.queued.rawValue
                    batch.updatedAt = Date()
                }
                try context.save()
                return openBatches.map { $0.objectID }
            } catch {
                print("Failed to enqueue open batches: \(error)")
                return []
            }
        }
        if !openBatchIDs.isEmpty {
            enqueuePendingProcessing()
        }
    }

    func scheduleBackgroundProcessing() {
        guard supportsBackgroundTasks else { return }
        let prefs = preferences
        guard prefs.autoProcessInbox else { return }
        guard prefs.allowsImageUploads else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
            guard let self else { return }
            guard !requests.contains(where: { $0.identifier == self.taskIdentifier }) else { return }
            self.submitBackgroundProcessingRequest(with: prefs)
        }
    }

    func rescheduleBackgroundProcessing() {
        let prefs = preferences
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
            guard let self else { return }
            if requests.contains(where: { $0.identifier == self.taskIdentifier }) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.taskIdentifier)
            }
            guard prefs.autoProcessInbox else { return }
            guard prefs.allowsImageUploads else { return }
            self.submitBackgroundProcessingRequest(with: prefs)
        }
    }

    private func submitBackgroundProcessingRequest(with prefs: ProcessingPreferences) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = prefs.requiresExternalPower

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule processing task: \(error)")
        }
    }

    private func handleBackgroundTask(_ task: BGTask) {
        guard supportsBackgroundTasks else {
            task.setTaskCompleted(success: false)
            return
        }
        scheduleBackgroundProcessing()
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        guard let processing = startProcessingIfNeeded() else {
            task.setTaskCompleted(success: true)
            return
        }

        processingTask.expirationHandler = { processing.cancel() }

        Task {
            let success = await processing.value
            task.setTaskCompleted(success: success)
        }
    }

    private func startProcessingIfNeeded() -> Task<Bool, Never>? {
        guard beginProcessingIfNeeded() else { return nil }
        return Task { [weak self] in
            defer { self?.endProcessing() }
            guard let self else { return false }
            return await self.processPendingBatches()
        }
    }

    private func beginProcessingIfNeeded() -> Bool {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard !isProcessing else { return false }
        isProcessing = true
        return true
    }

    private var supportsBackgroundTasks: Bool {
#if targetEnvironment(simulator)
        return false
#else
        return true
#endif
    }

    private func endProcessing() {
        processingLock.lock()
        isProcessing = false
        processingLock.unlock()
    }

    private func processPendingBatchesIfNeeded() {
        _ = startProcessingIfNeeded()
    }

    private func hasRequiredPower() async -> Bool {
        let prefs = preferences
        guard prefs.requiresExternalPower else { return true }
        return await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }
    }

    private func hasRequiredNetwork() async -> Bool {
        let prefs = preferences
        if prefs.requiresWiFi {
            return await NetworkConstraintChecker.isWiFiAvailable()
        }
        return await NetworkConstraintChecker.isNetworkAvailable()
    }

    private func processPendingBatches() async -> Bool {
        let prefs = preferences
        guard prefs.autoProcessInbox else { return true }
        guard prefs.allowsImageUploads else { return true }
        guard await hasRequiredPower() else {
            scheduleBackgroundProcessing()
            return true
        }
        guard await hasRequiredNetwork() else {
            scheduleBackgroundProcessing()
            return true
        }

        let context = persistenceController.container.newBackgroundContext()
        let batchIDs: [NSManagedObjectID] = await context.perform {
            let request = BatchEntity.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", BatchStatus.queued.rawValue)
            request.sortDescriptors = [
                NSSortDescriptor(key: "notebook.id", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true)
            ]
            do {
                return try context.fetch(request).map { $0.objectID }
            } catch {
                print("Failed to fetch queued batches: \(error)")
                return []
            }
        }

        guard !batchIDs.isEmpty else { return true }

        let client: GeminiClient
        do {
            client = try GeminiClient.makeDefault()
        } catch {
            await markBatchesBlocked(batchIDs, context: context)
            return false
        }

        let mode = preferences.qualityMode
        var allSucceeded = true
        for objectID in batchIDs {
            if Task.isCancelled { return false }
            let success = await processBatch(
                objectID: objectID,
                context: context,
                client: client,
                mode: mode
            )
            if !success {
                allSucceeded = false
            }
        }
        await SyncCoordinator.shared.syncIfNeeded(trigger: .processing)
        return allSucceeded
    }

    private func processBatch(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        client: GeminiClient,
        mode: ProcessingQualityMode
    ) async -> Bool {
        let batchDetails: (scanIDs: [NSManagedObjectID], rulesOverrides: String?) = await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
                return ([], nil)
            }
            batch.status = BatchStatus.processing.rawValue
            batch.updatedAt = Date()
            do {
                try context.save()
            } catch {
                return ([], nil)
            }
            let sortedScans = batch.scans.sorted { left, right in
                let leftPage = left.pageNumber?.intValue ?? 0
                let rightPage = right.pageNumber?.intValue ?? 0
                let leftHasPage = leftPage > 0
                let rightHasPage = rightPage > 0
                if leftHasPage && rightHasPage && leftPage != rightPage {
                    return leftPage < rightPage
                }
                if left.createdAt != right.createdAt {
                    return left.createdAt < right.createdAt
                }
                return left.id.uuidString < right.id.uuidString
            }
            return (sortedScans.map { $0.objectID }, batch.notebook?.rulesOverrides)
        }

        guard !batchDetails.scanIDs.isEmpty else { return false }
        let batchStart = CFAbsoluteTimeGetCurrent()
        let processingContext = ProcessingContextLoader.load(rulesOverrides: batchDetails.rulesOverrides)

        var batchSucceeded = true
        var wasCancelled = false
        for scanID in batchDetails.scanIDs {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            let success = await processScan(
                objectID: scanID,
                context: context,
                client: client,
                mode: mode,
                processingContext: processingContext
            )
            if !success {
                batchSucceeded = false
            }
        }

        if wasCancelled {
            await resetBatchStatusOnCancellation(objectID: objectID, context: context)
            return false
        }

        let hasScanError = await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
                return true
            }
            return batch.scans.contains { ScanStatus(rawValue: $0.status) == .error }
        }

        await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { return }
            batch.status = hasScanError ? BatchStatus.blocked.rawValue : BatchStatus.done.rawValue
            batch.updatedAt = Date()
            try? context.save()
        }

        let batchDuration = CFAbsoluteTimeGetCurrent() - batchStart
        await MainActor.run {
            PerformanceMetricsStore.shared.recordDuration(.processingBatchDuration, seconds: batchDuration)
        }

        return batchSucceeded && !hasScanError
    }

    private func resetBatchStatusOnCancellation(objectID: NSManagedObjectID, context: NSManagedObjectContext) async {
        await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { return }
            batch.status = BatchStatus.queued.rawValue
            batch.updatedAt = Date()
            for scan in batch.scans {
                let status = ScanStatus(rawValue: scan.status)
                if status == .transcribing || status == .structured {
                    scan.status = ScanStatus.preprocessing.rawValue
                }
            }
            try? context.save()
        }
    }

    private func processScan(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        client: GeminiClient,
        mode: ProcessingQualityMode,
        processingContext: ProcessingContextSnapshot
    ) async -> Bool {
        guard let snapshot = await loadScanSnapshot(objectID: objectID, context: context) else {
            return false
        }

        let scanStart = CFAbsoluteTimeGetCurrent()
        var shouldRecordDuration = false
        defer {
            if shouldRecordDuration {
                let duration = CFAbsoluteTimeGetCurrent() - scanStart
                Task { @MainActor in
                    PerformanceMetricsStore.shared.recordDuration(.processingScanDuration, seconds: duration)
                }
            }
        }

        switch snapshot.status {
        case .filed:
            return true
        case .error:
            return false
        case .structured:
            do {
                shouldRecordDuration = true
                let writerInput = try writerInput(from: snapshot)
                return await fileStructuredScan(objectID: objectID, context: context, writerInput: writerInput)
            } catch {
                await markScanError(objectID: objectID, context: context)
                return false
            }
        default:
            break
        }

        shouldRecordDuration = true
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
            scan.status = ScanStatus.transcribing.rawValue
            try? context.save()
        }

        do {
            let input = try loadScanInput(imagePath: snapshot.processedPath ?? snapshot.imagePath)
            let output = try await ScanProcessingPipeline.process(
                input: input,
                mode: mode,
                client: client,
                context: processingContext
            )
            guard let writerInput = await persistStructuredOutput(
                objectID: objectID,
                context: context,
                output: output
            ) else {
                return false
            }
            return await fileStructuredScan(objectID: objectID, context: context, writerInput: writerInput)
        } catch {
            await markScanError(objectID: objectID, context: context)
            return false
        }
    }

    private func loadScanSnapshot(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext
    ) async -> ScanSnapshot? {
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else {
                return nil
            }
            guard let status = ScanStatus(rawValue: scan.status) else {
                return nil
            }
            return ScanSnapshot(
                id: scan.id,
                batchId: scan.batch?.id,
                createdAt: scan.createdAt,
                status: status,
                imagePath: scan.imagePath,
                processedPath: scan.processedImagePath,
                transcriptJSON: scan.transcriptJSON,
                structuredJSON: scan.structuredJSON,
                ocrText: scan.ocrText,
                structuredMarkdown: scan.structuredMarkdown
            )
        }
    }

    private func persistStructuredOutput(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        output: ScanProcessingOutput
    ) async -> VaultWriterInput? {
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else {
                return nil
            }
            scan.ocrText = output.transcript.rawTranscript
            scan.confidence = output.transcript.confidence.map { NSNumber(value: $0) }
            scan.transcriptJSON = output.transcriptJSON
            scan.structuredMarkdown = output.structured.markdown
            scan.structuredJSON = output.structuredJSON
            scan.status = ScanStatus.structured.rawValue
            try? context.save()
            return VaultWriterInput(
                scanId: scan.id,
                batchId: scan.batch?.id,
                capturedAt: scan.createdAt,
                imagePath: scan.imagePath,
                processedImagePath: scan.processedImagePath,
                transcript: output.transcript,
                transcriptJSON: output.transcriptJSON,
                structured: output.structured,
                structuredJSON: output.structuredJSON
            )
        }
    }

    private func writerInput(from snapshot: ScanSnapshot) throws -> VaultWriterInput {
        let decoder = JSONDecoder()
        guard let structuredJSON = snapshot.structuredJSON ?? snapshot.transcriptJSON,
              let structuredData = structuredJSON.data(using: .utf8) else {
            throw VaultWriterError.invalidPayload
        }
        let structured = try decoder.decode(StructurePayload.self, from: structuredData)

        let transcriptJSON = snapshot.transcriptJSON ?? structuredJSON
        guard let transcriptData = transcriptJSON.data(using: .utf8) else {
            throw VaultWriterError.invalidPayload
        }
        let transcript = try decoder.decode(TranscriptionPayload.self, from: transcriptData)

        return VaultWriterInput(
            scanId: snapshot.id,
            batchId: snapshot.batchId,
            capturedAt: snapshot.createdAt,
            imagePath: snapshot.imagePath,
            processedImagePath: snapshot.processedPath,
            transcript: transcript,
            transcriptJSON: snapshot.transcriptJSON ?? structuredJSON,
            structured: structured,
            structuredJSON: structuredJSON
        )
    }

    private func fileStructuredScan(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        writerInput: VaultWriterInput
    ) async -> Bool {
        do {
            let result = try VaultWriter.apply(input: writerInput)
            await context.perform {
                guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
                scan.status = ScanStatus.filed.rawValue
                try? context.save()
            }
            await upsertNoteEntity(
                context: context,
                notePath: result.notePath,
                noteTitle: result.noteTitle,
                noteMeta: result.noteMeta
            )
            await VaultIndexStore.shared.updateAfterNoteWrite(
                notePath: result.notePath,
                noteTitle: result.noteTitle,
                noteMeta: result.noteMeta,
                context: context
            )
            if !result.createdEntities.isEmpty {
                for entity in result.createdEntities {
                    let entityMeta = NoteMeta(title: entity.title, summary: nil, tags: nil, links: nil)
                    await upsertNoteEntity(
                        context: context,
                        notePath: entity.path,
                        noteTitle: entity.title,
                        noteMeta: entityMeta
                    )
                    await VaultIndexStore.shared.updateAfterNoteWrite(
                        notePath: entity.path,
                        noteTitle: entity.title,
                        noteMeta: entityMeta,
                        context: context
                    )
                }
            }
            await TaskConsolidator.refreshIfEnabled(context: context)
            await TopicPageStore.refreshIfEnabled(context: context)
            return true
        } catch {
            await markScanError(objectID: objectID, context: context)
            return false
        }
    }

    private func upsertNoteEntity(
        context: NSManagedObjectContext,
        notePath: String,
        noteTitle: String,
        noteMeta: NoteMeta
    ) async {
        await context.perform {
            let request = NoteEntity.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "path == %@", notePath)
            let now = Date()
            if let existing = try? context.fetch(request).first {
                existing.title = noteTitle
                existing.summary = noteMeta.summary
                existing.tags = noteMeta.tags
                existing.links = noteMeta.links
                existing.updatedAt = now
            } else {
                let note = NoteEntity(context: context)
                note.id = UUID()
                note.path = notePath
                note.title = noteTitle
                note.summary = noteMeta.summary
                note.tags = noteMeta.tags
                note.links = noteMeta.links
                note.createdAt = now
                note.updatedAt = now
            }
            try? context.save()
        }
    }

    private func markScanError(objectID: NSManagedObjectID, context: NSManagedObjectContext) async {
        await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
            scan.status = ScanStatus.error.rawValue
            try? context.save()
        }
    }

    private func loadScanInput(imagePath: String) throws -> ScanProcessingInput {
        let url = try VaultScanStore.url(for: imagePath)
        let data = try VaultFileStore.readData(from: url)
        guard !data.isEmpty else {
            throw ProcessingPipelineError.invalidImageData
        }
        return ScanProcessingInput(imageData: data, mimeType: mimeType(for: imagePath))
    }

    private func mimeType(for path: String) -> String {
        let lowercased = (path as NSString).pathExtension.lowercased()
        switch lowercased {
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        default:
            return "image/jpeg"
        }
    }

    private func markBatchesBlocked(_ batchIDs: [NSManagedObjectID], context: NSManagedObjectContext) async {
        await context.perform {
            for objectID in batchIDs {
                guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { continue }
                batch.status = BatchStatus.blocked.rawValue
                batch.updatedAt = Date()
            }
            try? context.save()
        }
    }
}

enum NetworkConstraintChecker {
    static func isNetworkAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "marginshot.network.monitor")
            monitor.pathUpdateHandler = { path in
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
            monitor.pathUpdateHandler = { path in
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
}

enum FolderSyncer {
    private static let fileManager = FileManager.default
    private static let excludedSearchFiles: Set<String> = [
        "_system/search.sqlite",
        "_system/search.sqlite-wal",
        "_system/search.sqlite-shm"
    ]

    static func syncVault(to destinationURL: URL, userDefaults: UserDefaults = .standard) throws {
        let vaultURL = try vaultRootURL()
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        let previousManifest = SyncManifestStore.loadFolderManifest(for: destinationURL, userDefaults: userDefaults)
        let currentManifest = try syncDirectory(from: vaultURL, to: destinationURL, userDefaults: userDefaults)
        let removed = previousManifest.subtracting(currentManifest)
        try deleteRemovedFiles(removed, in: destinationURL)
        SyncManifestStore.saveFolderManifest(currentManifest, for: destinationURL, userDefaults: userDefaults)
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw FolderSyncError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }

    @discardableResult
    private static func syncDirectory(from sourceURL: URL, to destinationURL: URL, userDefaults: UserDefaults = .standard) throws -> Set<String> {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var syncedFiles = Set<String>()
        for case let fileURL as URL in enumerator {
            let relativePath = relativePath(from: sourceURL, to: fileURL)
            if excludedSearchFiles.contains(relativePath) {
                continue
            }
            let targetURL = destinationURL.appendingPathComponent(relativePath)
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])

            if resourceValues.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
                continue
            }

            if try shouldCopyFile(from: fileURL, to: targetURL, userDefaults: userDefaults) {
                let parent = targetURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
                try replaceItem(at: targetURL, with: fileURL)
            }
            syncedFiles.insert(relativePath)
        }
        return syncedFiles
    }

    private static func deleteRemovedFiles(_ removed: Set<String>, in destinationURL: URL) throws {
        guard !removed.isEmpty else { return }
        let rootURL = destinationURL.standardizedFileURL
        var deletedPaths: [String] = []
        for relativePath in removed {
            guard !relativePath.isEmpty else { continue }
            let targetURL = destinationURL.appendingPathComponent(relativePath)
            guard isInside(targetURL, rootURL: rootURL) else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    continue
                }
                try fileManager.removeItem(at: targetURL)
                deletedPaths.append(relativePath)
            }
        }
        removeEmptyDirectories(for: deletedPaths, rootURL: rootURL)
    }

    private static func isInside(_ url: URL, rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func removeEmptyDirectories(for deletedPaths: [String], rootURL: URL) {
        guard !deletedPaths.isEmpty else { return }
        for relativePath in deletedPaths {
            var directoryURL = rootURL.appendingPathComponent(relativePath).deletingLastPathComponent()
            while isInside(directoryURL, rootURL: rootURL), directoryURL != rootURL {
                if let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                    if contents.isEmpty {
                        try? fileManager.removeItem(at: directoryURL)
                        directoryURL.deleteLastPathComponent()
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }
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

    private static func shouldCopyFile(from sourceURL: URL, to destinationURL: URL, userDefaults: UserDefaults = .standard) throws -> Bool {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return true
        }
        let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let destinationAttributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        if let sourceSize = sourceAttributes[.size] as? NSNumber,
           let destinationSize = destinationAttributes[.size] as? NSNumber,
           sourceSize != destinationSize {
            return true
        }
        if let sourceDate = sourceAttributes[.modificationDate] as? Date,
           let destinationDate = destinationAttributes[.modificationDate] as? Date,
           sourceDate > destinationDate {
            return true
        }
        return false
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}

actor SyncCoordinator {
    static let shared = SyncCoordinator()

    private var isSyncing = false

    func syncIfNeeded(trigger: SyncTrigger) async {
        let prefs = SyncPreferences()
        await SyncStatusStore.shared.updateDestination(prefs.destination)
        guard !isSyncing else { return }
        guard await constraintsSatisfied(prefs, destination: prefs.destination) else { return }
        switch prefs.destination {
        case .off:
            return
        case .folder:
            await performFolderSync(trigger: trigger)
        case .github:
            await performGitHubSync(trigger: trigger)
        case .gitRemote:
            await SyncStatusStore.shared.markError("Custom Git remote sync is not available yet.")
        }
    }

    private func performFolderSync(trigger: SyncTrigger) async {
        guard let destinationURL = SyncFolderSelection.resolveURL() else {
            await SyncStatusStore.shared.markError("Select a folder in Settings to enable sync.")
            return
        }

        isSyncing = true
        await SyncStatusStore.shared.markSyncing()
        defer { isSyncing = false }

        do {
            try FolderSyncer.syncVault(to: destinationURL)
            await SyncStatusStore.shared.markIdle()
        } catch {
            print("Sync failed (\(trigger.rawValue)): \(error)")
            await SyncStatusStore.shared.markError("Sync failed. \(error.localizedDescription)")
        }
    }

    private func performGitHubSync(trigger: SyncTrigger) async {
        isSyncing = true
        await SyncStatusStore.shared.markSyncing()
        defer { isSyncing = false }

        do {
            try await performWithRetries(maxAttempts: 3, baseDelay: 2) {
                try await GitHubSyncer.syncVault()
            }
            await SyncStatusStore.shared.markIdle()
        } catch let syncError as GitHubSyncError {
            if case .offline = syncError {
                print("Sync skipped (\(trigger.rawValue)): offline")
                await SyncStatusStore.shared.markIdleSkippingSync()
                return
            }
            print("Sync failed (\(trigger.rawValue)): \(syncError)")
            await SyncStatusStore.shared.markError(syncError.localizedDescription)
        } catch {
            print("Sync failed (\(trigger.rawValue)): \(error)")
            await SyncStatusStore.shared.markError("Sync failed. \(error.localizedDescription)")
        }
    }

    private func performWithRetries(
        maxAttempts: Int,
        baseDelay: TimeInterval,
        operation: @escaping () async throws -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch {
                attempt += 1
                if attempt >= maxAttempts || !shouldRetry(error) {
                    throw error
                }
                let delay = min(baseDelay * pow(2, Double(attempt - 1)), 30)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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

    static func syncVault() async throws {
        guard let token = KeychainStore.readString(forKey: KeychainStore.githubAccessTokenKey) else {
            throw GitHubSyncError.missingToken
        }
        guard let selection = GitHubRepoSelection.load() else {
            throw GitHubSyncError.missingRepository
        }
        let vaultURL = try vaultRootURL()
        let defaults = UserDefaults.standard
        let lastSyncKey = GitHubDefaults.lastSyncAtKey(
            owner: selection.owner,
            name: selection.name,
            branch: selection.branch
        )
        let lastSyncAt = defaults.object(forKey: lastSyncKey) as? Date
        let snapshot = try vaultSnapshot(in: vaultURL, since: lastSyncAt)
        let previousManifest = SyncManifestStore.loadGitHubManifest(selection: selection)
        let removed = previousManifest.subtracting(snapshot.manifest)
        guard !snapshot.changed.isEmpty || !removed.isEmpty else { return }

        for file in snapshot.changed {
            try await upload(file: file, selection: selection, token: token)
        }
        if !removed.isEmpty {
            try await deleteRemovedFiles(removed, selection: selection, token: token)
        }
        SyncManifestStore.saveGitHubManifest(snapshot.manifest, selection: selection)
        defaults.set(Date(), forKey: lastSyncKey)
        defaults.removeObject(forKey: GitHubDefaults.lastSyncAtLegacyKey)
    }

    private struct VaultFile {
        let url: URL
        let relativePath: String
        let modifiedAt: Date?
    }

    private static func vaultSnapshot(in rootURL: URL, since date: Date?) throws -> (changed: [VaultFile], manifest: Set<String>) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var files: [VaultFile] = []
        var manifest = Set<String>()
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                continue
            }
            let modifiedAt = values.contentModificationDate
            let relativePath = relativePath(from: rootURL, to: fileURL)
            if excludedSearchFiles.contains(relativePath) {
                continue
            }
            manifest.insert(relativePath)
            let isChanged: Bool
            if let date {
                if let modifiedAt {
                    isChanged = modifiedAt > date
                } else {
                    isChanged = true
                }
            } else {
                isChanged = true
            }
            if isChanged {
                files.append(VaultFile(url: fileURL, relativePath: relativePath, modifiedAt: modifiedAt))
            }
        }
        let sorted = files.sorted { $0.relativePath < $1.relativePath }
        return (sorted, manifest)
    }

    private static func upload(
        file: VaultFile,
        selection: GitHubRepoSelection,
        token: String
    ) async throws {
        do {
            let data = try Data(contentsOf: file.url)
            let content = data.base64EncodedString()
            let message = "Sync vault: \(file.relativePath)"
            try await putContentWithSHAFallback(
                token: token,
                selection: selection,
                relativePath: file.relativePath,
                content: content,
                message: message
            )
        } catch let syncError as GitHubSyncError {
            throw syncError
        } catch let apiError as GitHubAPIError {
            throw mapGitHubError(apiError)
        } catch {
            throw mapTransportError(error)
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
