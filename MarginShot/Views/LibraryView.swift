import CoreData
import SwiftUI

struct LibraryView: View {
    @Binding var mode: AppMode
    @Binding var importRequested: Bool
    @State private var query = ""
    @State private var notes: [LibraryNote] = []
    @State private var error: String?
    @State private var loading = true
    @State private var refreshID = UUID()
    @State private var pageLimit = 100
    @State private var pendingPresented = false
    @State private var store = LibraryStore.makeDefault()
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "status != %@", ScanStatus.filed.rawValue)) private var pending: FetchedResults<ScanEntity>

    var body: some View {
        List {
            if !pending.isEmpty {
                Button { pendingPresented = true } label: { Label("Pending scans (\(pending.count))", systemImage: "tray") }
            }
            if let error {
                ContentUnavailableView {
                    Label("Library needs attention", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("Try Again") { refreshID = UUID() } }
            } else if loading && notes.isEmpty {
                ProgressView("Loading notes…")
            } else if notes.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("Make room for your ideas", systemImage: "books.vertical")
                    } description: { Text("Scan or import a page. Completed notes will appear here.") } actions: {
                        Button("Scan a page") { mode = .capture }
                        Button("Import Photos") { mode = .capture; importRequested = true }
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                    Button("Clear search") { query = "" }
                }
            } else {
                ForEach(notes) { note in
                    NavigationLink {
                        NoteDetailView(path: note.path, store: store)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            if let original = note.originalPaths.first {
                                OriginalPageImage(path: original, store: store)
                                    .frame(width: 52, height: 72).clipped().accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(note.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(note.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                if let date = note.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .accessibilityIdentifier("libraryNote-" + note.path)
                }
                if notes.count == pageLimit {
                    Button("Load more notes") { pageLimit += 100 }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your notes")
        .settingsToolbar()
        .task(id: query + refreshID.uuidString + String(pageLimit)) {
            loading = true
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                var result: [LibraryNote] = []
                for offset in stride(from: 0, to: pageLimit, by: 100) {
                    result += try await store.notes(query: query, offset: offset)
                }
                try Task.checkCancellation()
                notes = result
                error = nil
                loading = false
            } catch is CancellationError {} catch {
                self.error = error.localizedDescription
                loading = false
            }
        }
        .refreshable { await refreshSnapshot() }
        .task(id: pending.count) {
            guard !loading else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await refreshSnapshot()
            } catch {}
        }
        .sheet(isPresented: $pendingPresented) { PendingScansView() }
    }
    @MainActor
    private func refreshSnapshot() async {
        do {
            _ = try await store.notes(query: "", limit: 1, refresh: true)
            try Task.checkCancellation()
            refreshID = UUID()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

}

/// Pending scans uses the existing retry adapter without starting a camera session.
struct PendingScansView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var adapter = DesignFixture.current?.captureModel() ?? CaptureViewModel()
    var body: some View {
        InboxSheet(viewModel: adapter).onAppear { adapter.bind(context: context) }
    }
}

struct NoteDetailView: View {
    let path: String
    var store: LibraryStore = .makeDefault()
    @State private var content: LibraryNoteContent?
    @State private var error: String?
    @State private var retryID = UUID()
    @State private var showRaw = false

    var body: some View {
        ScrollView {
            if let content {
                VStack(alignment: .leading, spacing: 20) {
                    Text(content.note.title).font(.largeTitle.bold())
                    if let date = content.note.date { Text(date, style: .date).font(.subheadline).foregroundStyle(.secondary) }
                    Toggle("Show complete raw text", isOn: $showRaw).font(.callout)
                    if showRaw {
                        Text(content.markdown).font(.body.monospaced()).textSelection(.enabled)
                    } else {
                        MarkdownNoteBody(markdown: content.markdown)
                    }
                    if !content.note.originalPaths.isEmpty {
                        NavigationLink("Original pages (\(content.note.originalPaths.count))") {
                            OriginalPagesView(paths: content.note.originalPaths, store: store)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            } else if let error {
                ContentUnavailableView {
                    Label("Note unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("Try Again") { retryID = UUID() } }
            } else { ProgressView("Reading note…").padding() }
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .task(id: retryID) {
            do { content = try await store.content(path: path); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct MarkdownNoteBody: View {
    let markdown: String

    private var parts: (body: String, raw: String?) {
        let markers = ["\n## Raw transcription\n", "\n### Raw transcription\n"]
        let found = markers.filter { markdown.contains($0) }
        if found.count == 1 {
            let chunks = markdown.components(separatedBy: found[0])
            if chunks.count == 2 && !chunks[0].contains("```") && !chunks[1].split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("#") }) {
                return (chunks[0], chunks[1])
            }
        }
        return (markdown, nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(parts.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { index, block in
                if index == 0 && block.hasPrefix("# ") && !block.contains("\n") {
                    EmptyView()
                } else if block.hasPrefix("# ") {
                    Text(String(block.dropFirst(2))).font(.title2.bold())
                } else if block.hasPrefix("## ") {
                    Text(String(block.dropFirst(3))).font(.title3.bold())
                } else if block.contains("```") || block.contains("|") {
                    Text(block).font(.body.monospaced()).textSelection(.enabled)
                } else {
                    Text(.init(block)).font(.body).textSelection(.enabled)
                }
            }
            if let raw = parts.raw {
                DisclosureGroup("Raw transcription") { Text(raw).font(.body).textSelection(.enabled).padding(.top, 8) }
            }
        }
    }
}

struct OriginalPagesView: View {
    let paths: [String]
    let store: LibraryStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Page \(index + 1)").font(.headline)
                        OriginalPageImage(path: path, store: store)
                    }
                }
            }.padding(20)
        }
        .navigationTitle("Original pages")
    }
}

struct OriginalPageImage: View {
    let path: String
    let store: LibraryStore
    @State private var data: Data?
    @State private var failed = false
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Original notebook page")
            } else if failed { Label("Page could not be opened", systemImage: "exclamationmark.triangle") }
            else { ProgressView("Loading page…") }
        }
        .task(id: path) {
            do { let loaded = try await store.thumbnail(path: path); try Task.checkCancellation(); data = loaded }
            catch is CancellationError {} catch { failed = true }
        }
        .onDisappear { data = nil }
    }
}
