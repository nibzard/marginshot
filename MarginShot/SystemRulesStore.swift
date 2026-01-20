import Foundation

enum SystemRulesStore {
    static let defaultRules = """
    # System Rules

    - Depth over breadth; prioritize clean, composable notes.
    - Prefer claim-style headings when confident.
    - Weave wiki-links inline when referencing concepts or projects.
    - Don't invent facts; mark uncertain items as TODO.
    - Keep a raw transcription section for traceability.
    """

    static func load() -> String {
        do {
            try ensureExists()
            let url = try fileURL()
            return try VaultFileStore.readText(from: url)
        } catch {
            return defaultRules
        }
    }

    static func loadForPrompt(maxCharacters: Int = 8000) -> String {
        loadForPrompt(overrides: nil, maxCharacters: maxCharacters)
    }

    static func loadForPrompt(overrides: String?, maxCharacters: Int = 8000) -> String {
        let baseRules = load()
        let trimmedOverrides = overrides?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined: String
        if trimmedOverrides.isEmpty {
            combined = baseRules
        } else {
            combined = """
            \(baseRules)

            # Notebook Rules Overrides

            \(trimmedOverrides)
            """
        }
        guard combined.count > maxCharacters else { return combined }
        let endIndex = combined.index(combined.startIndex, offsetBy: maxCharacters)
        return String(combined[..<endIndex])
    }

    static func save(_ rules: String) throws {
        let url = try fileURL()
        let directoryURL = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        try VaultFileStore.writeText(rules, to: url)
    }

    static func reset() throws {
        try save(defaultRules)
    }

    private static func ensureExists() throws {
        let url = try fileURL()
        let directoryURL = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        if !fileManager.fileExists(atPath: url.path) {
            try VaultFileStore.writeText(defaultRules, to: url)
        }
    }

    private static func fileURL() throws -> URL {
        let rootURL = try vaultRootURL()
        return rootURL.appendingPathComponent("_system/SYSTEM.md")
    }

    private static func vaultRootURL() throws -> URL {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw SystemRulesError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }
}

enum SystemRulesError: Error {
    case documentsDirectoryUnavailable
}
