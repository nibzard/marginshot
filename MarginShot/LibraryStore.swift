import Foundation
import ImageIO
import UIKit

struct LibraryNote: Identifiable, Hashable {
    let path: String
    let title: String
    let excerpt: String
    let date: Date?
    let originalPaths: [String]
    var id: String { path }
}

struct LibraryNoteContent {
    let note: LibraryNote
    let markdown: String
}

enum LibraryError: LocalizedError {
    case indexUnavailable
    var errorDescription: String? { "Your Library could not be read. Your notes are preserved. Check storage or encryption access, then try again." }
}

/// Decoding, search, metadata association, and thumbnails run away from the main actor.
actor LibraryStore {
    let root: URL
    let defaults: UserDefaults
    let index: VaultIndexStore
    private var prepared = false
    private var sourceAssociations: [String: [String]] = [:]

    init(root: URL? = nil, defaults: UserDefaults = .standard, controller: PersistenceController = .shared) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("vault")
        self.defaults = defaults
        self.index = VaultIndexStore(rootURL: self.root, persistenceController: controller, userDefaults: defaults)
    }

    static func makeDefault() -> LibraryStore {
        if let fixture = DesignFixture.current { return LibraryStore(root: fixture.root, defaults: fixture.defaults, controller: fixture.controller) }
        return LibraryStore()
    }

    func notes(query: String, limit: Int = 100, offset: Int = 0, refresh: Bool = false) async throws -> [LibraryNote] {
        if !prepared || refresh {
            guard await IndexWorker.shared.process(store: index) else { prepared = false; throw LibraryError.indexUnavailable }
            sourceAssociations = try loadOriginalAssociations()
            prepared = true
        }
        try Task.checkCancellation()
        let entries: [IndexNoteEntry]
        do { entries = try index.libraryEntries(query: query, limit: limit, offset: offset) }
        catch { prepared = false; throw error }
        return try entries.map { entry in
            try Task.checkCancellation()
            let content = try read(path: entry.path)
            return LibraryNote(path: entry.path, title: entry.title, excerpt: entry.summary ?? String(content.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.joined(separator: " ").prefix(200)), date: try modificationDate(path: entry.path), originalPaths: sourceAssociations[entry.path] ?? [])
        }
    }

    func content(path: String) throws -> LibraryNoteContent {
        let markdown = try read(path: path)
        let title = markdown.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return LibraryNoteContent(note: LibraryNote(path: path, title: title, excerpt: "", date: try modificationDate(path: path), originalPaths: try originalPages(notePath: path)), markdown: markdown)
    }

    private func read(path: String) throws -> String {
        guard path.hasSuffix(".md"), !path.hasPrefix("_system/"), !path.hasPrefix("scans/") else { throw VaultRepositoryError.invalidPath(path) }
        let repository = VaultRepository.register(rootURL: root, userDefaults: defaults)
        return try repository.withAccess {
            try VaultFileStore.readText(from: repository.validatedURL(path), userDefaults: defaults)
        }
    }

    private func modificationDate(path: String) throws -> Date? {
        let repository = VaultRepository.register(rootURL: root, userDefaults: defaults)
        return try repository.validatedURL(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Only committed scan sidecars establish association; dates/batch proximity never do.
    private func originalPages(notePath: String) throws -> [String] {
        try loadOriginalAssociations()[notePath] ?? []
    }

    private func loadOriginalAssociations() throws -> [String: [String]] {
        let repository = VaultRepository.register(rootURL: root, userDefaults: defaults)
        return try repository.withAccess {
            var paths: [String: Set<String>] = [:]
            if let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("scans"), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("capture-") {
                    try Task.checkCancellation()
                    guard let data = try? VaultFileStore.readData(from: url, userDefaults: defaults),
                          let metadata = try? JSONDecoder().decode(ScanMetadata.self, from: data) else { continue }
                    let path = metadata.imagePath
                    guard path.hasPrefix("scans/"), ["jpg", "jpeg", "png", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                          let original = try? repository.validatedURL(path), FileManager.default.fileExists(atPath: original.path) else { continue }
                    paths[metadata.notePath, default: []].insert(path)
                }
            }
            return paths.mapValues { $0.sorted() }
        }
    }

    func thumbnail(path: String, maxDimension: Int = 1000) throws -> Data {
        guard path.hasPrefix("scans/") else { throw VaultRepositoryError.invalidPath(path) }
        let repository = VaultRepository.register(rootURL: root, userDefaults: defaults)
        return try repository.withAccess {
            let data = try VaultFileStore.readData(from: repository.validatedURL(path), userDefaults: defaults)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, 2000), kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  let result = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { throw CaptureStoreError.unsupportedImage }
            return result
        }
    }
}
