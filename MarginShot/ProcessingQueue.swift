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
    let jobCheckpoint: String?
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

struct VaultWriteResult: Codable {
    let notePath: String
    let noteTitle: String
    let metadataPath: String
    let noteMeta: NoteMeta
    let createdEntities: [EntityPage]
}

struct EntityPage: Codable, Equatable {
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

    static func apply(input: VaultWriterInput, userDefaults: UserDefaults = .standard, rootURL: URL? = nil) throws -> VaultWriteResult {
        let rootURL = try rootURL ?? vaultRootURL()
        let repository = VaultRepository.register(rootURL: rootURL, userDefaults: userDefaults)
        return try repository.transaction(id: "scan:\(input.scanId.uuidString)") {
            try applyPrepared(input: input, userDefaults: userDefaults, rootURL: rootURL)
        }
    }

    private static func applyPrepared(input: VaultWriterInput, userDefaults: UserDefaults, rootURL: URL) throws -> VaultWriteResult {
        let metadataPath = VaultScanStore.metadataPath(for: input.processedImagePath ?? input.imagePath)
        let metadataURL = rootURL.appendingPathComponent(metadataPath)
        if fileManager.fileExists(atPath: metadataURL.path) {
            let existing = try JSONDecoder().decode(ScanMetadata.self, from: VaultFileStore.readData(from: metadataURL, userDefaults: userDefaults))
            if existing.scanId == input.scanId.uuidString,
               fileManager.fileExists(atPath: rootURL.appendingPathComponent(existing.notePath).path) {
                return VaultWriteResult(notePath: existing.notePath, noteTitle: existing.noteTitle, metadataPath: metadataPath, noteMeta: existing.structured.noteMeta, createdEntities: [])
            }
        }
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
        try VaultFileStore.writeData(metadataData, to: metadataURL, userDefaults: userDefaults)
        try VaultNoteMetadataStore.write(path: noteResult.path, noteMeta: normalizedStructured.noteMeta, rootURL: rootURL, userDefaults: userDefaults)
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
            if fileManager.fileExists(atPath: noteURL.path) {
                let existing = try VaultFileStore.readText(from: noteURL, userDefaults: userDefaults)
                if existing.contains("Scan: \(input.scanId.uuidString)") { return (notePath, dateString) }
            }
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
        let existing = fileManager.fileExists(atPath: url.path)
            ? try VaultFileStore.readText(from: url, userDefaults: userDefaults) : ""
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
    var expectedRevision: VaultExpectedRevision? = nil
}

struct VaultApplySummary: Codable, Equatable {
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
    }

    static func apply(
        _ operations: [VaultFileOperation],
        userDefaults: UserDefaults = .standard,
        rootURL: URL? = nil,
        indexStore: VaultIndexStore = .shared,
        operationID: String = UUID().uuidString,
        expectedRevisions: [String: VaultExpectedRevision] = [:],
        refreshDerivedPages: () async -> Void = {
            await TopicPageStore.refreshIfEnabled(context: nil)
            await TaskConsolidator.refreshIfEnabled(context: nil)
        }
    ) async throws -> VaultApplySummary {
        let sanitized = try sanitizeOperations(operations, userDefaults: userDefaults)
        guard !sanitized.isEmpty else { throw VaultApplyError.emptyOperations }
        let rootURL = try rootURL ?? vaultRootURL()
        let repository = VaultRepository.register(rootURL: rootURL, userDefaults: userDefaults)
        var expected = expectedRevisions
        for operation in sanitized {
            if let revision = operation.expectedRevision { expected[operation.path] = revision }
            else if operation.action == .create { expected[operation.path] = .missing }
            else if expected[operation.path] == nil {
                throw VaultRepositoryError.staleRevision(operation.path)
            }
        }
        let summary: VaultApplySummary = try repository.transaction(id: operationID, expected: expected) {
            var seen = Set<String>()
            // Validate every operation before staging or committing any change.
            for operation in sanitized {
                guard seen.insert(operation.path).inserted else {
                    throw VaultApplyError.invalidOperation("Duplicate path: \(operation.path)")
                }
                let target = try repository.validatedURL(operation.path)
                let exists = fileManager.fileExists(atPath: target.path)
                if operation.action == .create && exists {
                    throw VaultApplyError.invalidOperation("File already exists: \(operation.path)")
                }
                if operation.action != .create && !exists {
                    throw VaultApplyError.invalidOperation("File not found: \(operation.path)")
                }
                if operation.action != .delete {
                    guard let content = operation.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw VaultApplyError.invalidOperation("Missing content for \(operation.path)")
                    }
                }
            }
            for operation in sanitized {
                let target = try repository.validatedURL(operation.path)
                if operation.action == .delete {
                    try VaultRepository.removeItem(at: target)
                    let metadata = rootURL.appendingPathComponent(VaultNoteMetadataStore.metadataPath(for: operation.path))
                    if fileManager.fileExists(atPath: metadata.path) { try VaultRepository.removeItem(at: metadata) }
                } else {
                    try VaultFileStore.writeText(operation.content!, to: target, userDefaults: userDefaults)
                    try VaultNoteMetadataStore.write(path: operation.path, noteMeta: resolvedNoteMeta(for: operation, content: operation.content!), rootURL: rootURL, userDefaults: userDefaults)
                }
            }
            return VaultApplySummary(
                createdOrUpdated: sanitized.filter { $0.action != .delete }.map { $0.path },
                deleted: sanitized.filter { $0.action == .delete }.map { $0.path }
            )
        }
        let prepared = sanitized.map { PreparedOperation(operation: $0, path: $0.path) }
        await updateIndex(for: prepared, indexStore: indexStore)
        await refreshDerivedPages()
        return summary
    }

    private static func sanitizeOperations(_ operations: [VaultFileOperation], userDefaults: UserDefaults) throws -> [VaultFileOperation] {
        try operations.map { operation in
            let normalized = try normalizePath(operation.path, userDefaults: userDefaults)
            return VaultFileOperation(
                action: operation.action,
                path: normalized,
                content: operation.content,
                noteMeta: operation.noteMeta,
                expectedRevision: operation.expectedRevision
            )
        }
    }

    static func normalizePath(_ path: String, userDefaults: UserDefaults = .standard) throws -> String {
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
        let style = OrganizationPreferences(userDefaults: userDefaults).style
        return VaultFolder.normalizeTopLevelPath(trimmed, style: style)
    }

    private static func updateIndex(for operations: [PreparedOperation], indexStore: VaultIndexStore) async {
        for item in operations {
            switch item.operation.action {
            case .delete:
                await indexStore.removeNote(path: item.path, context: nil)
            case .create, .update:
                guard let content = item.operation.content else { continue }
                let meta = resolvedNoteMeta(for: item.operation, content: content)
                await indexStore.updateAfterNoteWrite(
                    notePath: item.path,
                    noteTitle: meta.title,
                    noteMeta: meta,
                    context: nil
                )
            }
        }
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
    private let vaultRootOverride: URL?
    private let userDefaults: UserDefaults
    private let indexStore: VaultIndexStore
    private let refreshDerivedPages: (NSManagedObjectContext) async -> Void
    private var taskIdentifier: String {
        Bundle.main.bundleIdentifier.map { "\($0).processing" } ?? "processing"
    }
    private let processingLock = NSLock()
    private var isProcessing = false
    private var processingRequested = false

    private var preferences: ProcessingPreferences {
        ProcessingPreferences()
    }

    init(
        persistenceController: PersistenceController = .shared,
        rootURL: URL? = nil,
        userDefaults: UserDefaults = .standard,
        indexStore: VaultIndexStore = .shared,
        refreshDerivedPages: @escaping (NSManagedObjectContext) async -> Void = { context in
            await TaskConsolidator.refreshIfEnabled(context: context)
            await TopicPageStore.refreshIfEnabled(context: context)
        }
    ) {
        self.persistenceController = persistenceController
        self.vaultRootOverride = rootURL
        self.userDefaults = userDefaults
        self.indexStore = indexStore
        self.refreshDerivedPages = refreshDerivedPages
    }

    func registerBackgroundTasks() {
        guard supportsBackgroundTasks else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
            Task {
                do {
                    try await AppRecovery.shared.prepare()
                    self?.handleBackgroundTask(task)
                } catch { task.setTaskCompleted(success: false) }
            }
        }
    }

    func enqueuePendingProcessing() {
        guard preferences.autoProcessInbox else { return }
        scheduleBackgroundProcessing()
        processPendingBatchesIfNeeded()
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
        guard !isProcessing else { processingRequested = true; return false }
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
        let shouldContinue = processingRequested
        processingRequested = false
        processingLock.unlock()
        if shouldContinue { processPendingBatchesIfNeeded() }
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

    private func pausePendingWork(reason: String) async {
        let context = persistenceController.container.newBackgroundContext()
        await context.perform {
            let request = BatchEntity.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", BatchStatus.queued.rawValue)
            do {
                for batch in try context.fetch(request) {
                    for scan in batch.scans where scan.status != ScanStatus.filed.rawValue && scan.jobState != ProcessingJobState.needsAttention.rawValue && scan.jobState != ProcessingJobState.retryScheduled.rawValue {
                        ProcessingJobStore.pause(scan: scan, category: reason)
                    }
                }
                try context.save()
            } catch { print("Processing pause persistence deferred: \(error)") }
        }
    }

    private func processPendingBatches() async -> Bool {
        let prefs = preferences
        guard prefs.autoProcessInbox else { return true }
        guard prefs.allowsImageUploads else {
            await pausePendingWork(reason: "privacy")
            return true
        }
        guard await hasRequiredPower() else {
            await pausePendingWork(reason: "charging")
            scheduleBackgroundProcessing()
            return true
        }
        guard await hasRequiredNetwork() else {
            await pausePendingWork(reason: "network")
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

        if wasCancelled || Task.isCancelled || (!batchSucceeded && !preferences.allowsImageUploads) {
            await resetBatchStatusOnCancellation(objectID: objectID, context: context)
            return false
        }

        let completion = await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else {
                return (hasError: true, allFiled: false)
            }
            return (hasError: batch.scans.contains { ScanStatus(rawValue: $0.status) == .error || $0.jobState == ProcessingJobState.needsAttention.rawValue },
                    allFiled: batch.scans.allSatisfy { ScanStatus(rawValue: $0.status) == .filed })
        }

        await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { return }
            batch.status = completion.hasError ? BatchStatus.blocked.rawValue : (completion.allFiled ? BatchStatus.done.rawValue : BatchStatus.queued.rawValue)
            batch.updatedAt = Date()
            try? context.save()
        }

        let batchDuration = CFAbsoluteTimeGetCurrent() - batchStart
        await MainActor.run {
            PerformanceMetricsStore.shared.recordDuration(.processingBatchDuration, seconds: batchDuration)
        }

        return batchSucceeded && completion.allFiled && !completion.hasError
    }

    private func resetBatchStatusOnCancellation(objectID: NSManagedObjectID, context: NSManagedObjectContext) async {
        await context.perform {
            guard let batch = try? context.existingObject(with: objectID) as? BatchEntity else { return }
            batch.status = BatchStatus.queued.rawValue
            batch.updatedAt = Date()
            for scan in batch.scans {
                let status = ScanStatus(rawValue: scan.status)
                if status != .filed && scan.jobState != ProcessingJobState.needsAttention.rawValue {
                    ProcessingJobStore.pause(scan: scan, category: "cancelledOrPrivacy")
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

        let eligible = await context.perform {
            guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return false }
            return scan.jobState != ProcessingJobState.needsAttention.rawValue && (scan.jobNextRetryAt.map { $0 <= Date() } ?? true)
        }
        guard eligible else { return false }
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
            scan.jobState = ProcessingJobState.running.rawValue
            scan.jobAttempts = NSNumber(value: (scan.jobAttempts?.intValue ?? 0) + 1)
            scan.jobFailure = nil
            try? context.save()
        }

        do {
            var inputPath = snapshot.processedPath
            if inputPath == nil {
                let rawURL = try VaultScanStore.url(for: snapshot.imagePath)
                let raw = try VaultFileStore.readData(from: rawURL)
                let processed = try DocumentProcessingPipeline.process(imageData: raw)
                let path = try VaultScanStore.saveProcessedScan(processedData: processed.processedData, rawPath: snapshot.imagePath)
                try await context.perform {
                    guard let scan = try context.existingObject(with: objectID) as? ScanEntity else { throw CaptureStoreError.metadataUnavailable }
                    scan.processedImagePath = path
                    scan.jobCheckpoint = "inputReady"
                    try context.save()
                }
                inputPath = path
            }
            try Task.checkCancellation()
            let input = try loadScanInput(imagePath: inputPath!)
            let output = try await ScanProcessingPipeline.process(
                input: input,
                mode: mode,
                client: client,
                context: processingContext,
                checkpoint: try processingCheckpoint(from: snapshot),
                saveCheckpoint: { checkpoint in
                    try await context.perform {
                        guard let scan = try context.existingObject(with: objectID) as? ScanEntity else { throw CaptureStoreError.metadataUnavailable }
                        scan.ocrText = checkpoint.transcript.rawTranscript
                        scan.transcriptJSON = checkpoint.transcriptJSON
                        scan.structuredJSON = checkpoint.structuredJSON
                        scan.structuredMarkdown = checkpoint.structured?.markdown
                        scan.jobCheckpoint = checkpoint.stage
                        scan.status = checkpoint.stage == "structured" ? ScanStatus.structured.rawValue : ScanStatus.transcribing.rawValue
                        try context.save()
                    }
                }
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
            if ProcessingInterruption.isPause(error) {
                await context.perform {
                    guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
                    ProcessingJobStore.pause(scan: scan, category: "cancelledOrPrivacy")
                    try? context.save()
                }
            } else if let clientError = error as? GeminiClientError, clientError.isRetryable {
                await context.perform {
                    guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return }
                    scan.status = ScanStatus.captured.rawValue
                    scan.jobState = ProcessingJobState.retryScheduled.rawValue
                    scan.jobFailure = "network"
                    scan.jobNextRetryAt = Date().addingTimeInterval(min(3600, pow(2, Double(scan.jobAttempts?.intValue ?? 1)) * 30))
                    try? context.save()
                }
            } else {
                await markScanError(objectID: objectID, context: context)
            }
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
                structuredMarkdown: scan.structuredMarkdown,
                jobCheckpoint: scan.jobCheckpoint
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
            scan.jobState = ProcessingJobState.pending.rawValue
            scan.jobCheckpoint = "structured"
            scan.jobNextRetryAt = nil
            do { try context.save() } catch {
                context.rollback()
                return nil
            }
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

    private func processingCheckpoint(from snapshot: ScanSnapshot) throws -> ProcessingCheckpoint? {
        guard let stage = snapshot.jobCheckpoint, ["transcribed", "organized", "structured"].contains(stage),
              let transcriptJSON = snapshot.transcriptJSON else { return nil }
        let transcript = try JSONDecoder().decode(TranscriptionPayload.self, from: Data(transcriptJSON.utf8))
        let structured = try snapshot.structuredJSON.map { try JSONDecoder().decode(StructurePayload.self, from: Data($0.utf8)) }
        return ProcessingCheckpoint(stage: stage, transcript: transcript, transcriptJSON: transcriptJSON, structured: structured, structuredJSON: snapshot.structuredJSON)
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

    func fileStructuredScan(
        objectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        writerInput: VaultWriterInput
    ) async -> Bool {
        do {
            let result = try VaultWriter.apply(input: writerInput, userDefaults: userDefaults, rootURL: vaultRootOverride)
            let completed = await context.perform {
                guard let scan = try? context.existingObject(with: objectID) as? ScanEntity else { return false }
                scan.status = ScanStatus.filed.rawValue
                scan.jobState = ProcessingJobState.complete.rawValue
                scan.jobCheckpoint = "filed"
                scan.jobFailure = nil
                scan.jobNextRetryAt = nil
                do { try context.save(); return true } catch { context.rollback(); return false }
            }
            guard completed else { return false }
            await upsertNoteEntity(
                context: context,
                notePath: result.notePath,
                noteTitle: result.noteTitle,
                noteMeta: result.noteMeta
            )
            await indexStore.updateAfterNoteWrite(
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
                    await indexStore.updateAfterNoteWrite(
                        notePath: entity.path,
                        noteTitle: entity.title,
                        noteMeta: entityMeta,
                        context: context
                    )
                }
            }
            await refreshDerivedPages(context)
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
            scan.jobState = ProcessingJobState.needsAttention.rawValue
            scan.jobFailure = "processing"
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
