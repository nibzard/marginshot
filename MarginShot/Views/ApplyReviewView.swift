import SwiftUI

struct ApplyReviewSheet: View {
    let message: ChatMessage
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ApplyReviewEntry] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    Section {
                        ProgressView("Preparing preview...")
                    }
                } else if entries.isEmpty {
                    Section {
                        Text("No changes to review.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text(summaryText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(entries) { entry in
                        ApplyReviewEntryView(entry: entry)
                    }
                }
            }
            .navigationTitle("Review changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        dismiss()
                        onApply()
                    }
                    .disabled(entries.isEmpty)
                }
            }
        }
        .task {
            entries = ApplyReviewBuilder.build(for: message.fileOps)
            isLoading = false
        }
    }

    private var summaryText: String {
        let total = entries.count
        let creates = entries.filter { $0.action == .create }.count
        let updates = entries.filter { $0.action == .update }.count
        let deletes = entries.filter { $0.action == .delete }.count
        var parts: [String] = []
        if creates > 0 { parts.append("\(creates) create") }
        if updates > 0 { parts.append("\(updates) update") }
        if deletes > 0 { parts.append("\(deletes) delete") }
        if parts.isEmpty {
            return "\(total) file change\(total == 1 ? "" : "s")"
        }
        return "\(total) file change\(total == 1 ? "" : "s"): " + parts.joined(separator: ", ")
    }
}

struct ApplyReviewEntryView: View {
    let entry: ApplyReviewEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.path)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(entry.actionLabel)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5), in: Capsule())
            }

            if !entry.warnings.isEmpty {
                ForEach(entry.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text(entry.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            DiffPreview(lines: entry.diffLines, truncated: entry.isTruncated)
        }
        .padding(.vertical, 6)
    }
}

struct DiffPreview: View {
    let lines: [DiffLine]
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty {
                Text("No preview available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            Text(verbatim: "\(line.prefix) \(line.text)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(line.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 180)
                .padding(8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
            }

            if truncated {
                Text("Preview limited to the first 200 lines.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind {
        case unchanged
        case added
        case removed
    }

    let id = UUID()
    let kind: Kind
    let text: String

    var prefix: String {
        switch kind {
        case .unchanged:
            return " "
        case .added:
            return "+"
        case .removed:
            return "-"
        }
    }

    var color: Color {
        switch kind {
        case .unchanged:
            return .secondary
        case .added:
            return .green
        case .removed:
            return .red
        }
    }
}

struct ApplyReviewEntry: Identifiable {
    let id = UUID()
    let action: VaultFileAction
    let path: String
    let diffLines: [DiffLine]
    let warnings: [String]
    let isTruncated: Bool

    var actionLabel: String {
        action.rawValue.capitalized
    }

    var summaryText: String {
        let added = diffLines.filter { $0.kind == .added }.count
        let removed = diffLines.filter { $0.kind == .removed }.count
        if added == 0 && removed == 0 {
            return "No line changes in preview."
        }
        if added > 0 && removed == 0 {
            return "\(added) line\(added == 1 ? "" : "s") added."
        }
        if removed > 0 && added == 0 {
            return "\(removed) line\(removed == 1 ? "" : "s") removed."
        }
        return "\(added) added, \(removed) removed."
    }
}

enum ApplyReviewBuilder {
    private static let allowedExtensions: Set<String> = ["md"]
    private static let disallowedRoots: Set<String> = ["_system", "scans"]
    private static let previewLineLimit = 200

    static func build(for operations: [VaultFileOperation]) -> [ApplyReviewEntry] {
        operations.map { operation in
            let (normalizedPath, validationWarning) = validatePath(operation.path)
            var warnings: [String] = []
            if let validationWarning {
                warnings.append(validationWarning)
            }

            let displayPath = normalizedPath ?? operation.path
            let existingContent = normalizedPath.flatMap(loadExistingContent)
            let exists = existingContent != nil

            switch operation.action {
            case .create:
                if exists {
                    warnings.append("File already exists.")
                }
            case .update, .delete:
                if !exists {
                    warnings.append("Existing file not found.")
                }
            }

            let proposedContent = operation.content
            if operation.action != .delete {
                if let content = proposedContent, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warnings.append("Proposed content is empty.")
                }
                if proposedContent == nil {
                    warnings.append("Missing proposed content.")
                }
            }

            let oldText = existingContent ?? ""
            let newText = operation.action == .delete ? "" : (proposedContent ?? "")
            let (diffLines, truncated) = DiffBuilder.build(oldText: oldText, newText: newText, limit: previewLineLimit)

            return ApplyReviewEntry(
                action: operation.action,
                path: displayPath,
                diffLines: diffLines,
                warnings: warnings,
                isTruncated: truncated
            )
        }
    }

    private static func validatePath(_ path: String) -> (String?, String?) {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, "Missing file path.")
        }
        if trimmed.hasPrefix("vault/") {
            trimmed.removeFirst("vault/".count)
        }
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else {
            return (nil, "Missing file path.")
        }
        let components = trimmed.split(separator: "/")
        if components.contains(where: { $0 == "." || $0 == ".." }) {
            return (nil, "Invalid path.")
        }
        if let first = components.first, disallowedRoots.contains(String(first)) {
            return (nil, "Path not allowed.")
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            return (nil, "Only .md files can be modified.")
        }
        let normalized = VaultFolder.normalizeTopLevelPath(trimmed, style: OrganizationPreferences().style)
        return (normalized, nil)
    }

    private static func loadExistingContent(path: String) -> String? {
        guard let fileURL = VaultPreviewLocation.fileURL(relativePath: path) else { return nil }
        return try? VaultFileStore.readText(from: fileURL)
    }
}

enum DiffBuilder {
    static func build(oldText: String, newText: String, limit: Int) -> ([DiffLine], Bool) {
        let (oldLines, oldTruncated) = lines(from: oldText, limit: limit)
        let (newLines, newTruncated) = lines(from: newText, limit: limit)
        let truncated = oldTruncated || newTruncated
        let diffLines = diff(oldLines: oldLines, newLines: newLines)
        return (diffLines, truncated)
    }

    private static func lines(from text: String, limit: Int) -> ([String], Bool) {
        let rawLines = text.split(whereSeparator: \.isNewline, omittingEmptySubsequences: false)
        if rawLines.count > limit {
            return (rawLines.prefix(limit).map(String.init), true)
        }
        return (rawLines.map(String.init), false)
    }

    private static func diff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let oldCount = oldLines.count
        let newCount = newLines.count
        if oldCount == 0 && newCount == 0 {
            return []
        }

        var lcs = Array(repeating: Array(repeating: 0, count: newCount + 1), count: oldCount + 1)
        if oldCount > 0 && newCount > 0 {
            for i in stride(from: oldCount - 1, through: 0, by: -1) {
                for j in stride(from: newCount - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        lcs[i][j] = lcs[i + 1][j + 1] + 1
                    } else {
                        lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
        }

        var diffLines: [DiffLine] = []
        var i = 0
        var j = 0

        while i < oldCount && j < newCount {
            if oldLines[i] == newLines[j] {
                diffLines.append(DiffLine(kind: .unchanged, text: oldLines[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                diffLines.append(DiffLine(kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                diffLines.append(DiffLine(kind: .added, text: newLines[j]))
                j += 1
            }
        }

        while i < oldCount {
            diffLines.append(DiffLine(kind: .removed, text: oldLines[i]))
            i += 1
        }

        while j < newCount {
            diffLines.append(DiffLine(kind: .added, text: newLines[j]))
            j += 1
        }

        return diffLines
    }
}

private enum VaultPreviewLocation {
    static func fileURL(relativePath: String) -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsURL
            .appendingPathComponent("vault", isDirectory: true)
            .appendingPathComponent(relativePath)
    }
}
