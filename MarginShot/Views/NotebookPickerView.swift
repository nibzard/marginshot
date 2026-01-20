import CoreData
import SwiftUI

struct NotebookPickerView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \NotebookEntity.createdAt, ascending: true)]
    )
    private var notebooks: FetchedResults<NotebookEntity>

    @Binding var selectedNotebookId: UUID?

    @State private var newNotebookName = ""
    @State private var nameDraft = ""
    @State private var rulesDraft = ""
    @State private var isDefaultDraft = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Notebooks") {
                    if notebooks.isEmpty {
                        Text("No notebooks yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(notebooks, id: \.objectID) { notebook in
                            Button {
                                selectNotebook(notebook)
                            } label: {
                                HStack {
                                    Text(notebook.name)
                                    Spacer()
                                    if notebook.id == selectedNotebook?.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("Switching notebooks applies to the next batch you capture.")
                }

                Section("Add Notebook") {
                    TextField("Notebook name", text: $newNotebookName)
                        .textInputAutocapitalization(.words)
                    Button("Add Notebook") {
                        addNotebook()
                    }
                    .disabled(newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if selectedNotebook != nil {
                    Section("Notebook Details") {
                        TextField("Notebook name", text: $nameDraft)
                            .textInputAutocapitalization(.words)
                        Toggle("Set as default notebook", isOn: $isDefaultDraft)
                        TextEditor(text: $rulesDraft)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                        Button("Save Notebook") {
                            saveSelectedNotebook()
                        }
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text("Rules overrides are appended to System Rules during processing.")
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Notebooks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                refreshSelection()
            }
            .onChange(of: selectedNotebookId) { _ in
                loadSelectedNotebook()
            }
            .onChange(of: notebooks.count) { _ in
                refreshSelection()
            }
        }
    }

    private var selectedNotebook: NotebookEntity? {
        if let selectedNotebookId,
           let match = notebooks.first(where: { $0.id == selectedNotebookId }) {
            return match
        }
        if let defaultNotebook = notebooks.first(where: { $0.isDefault }) {
            return defaultNotebook
        }
        return notebooks.first
    }

    private func selectNotebook(_ notebook: NotebookEntity) {
        selectedNotebookId = notebook.id
        statusMessage = nil
        loadSelectedNotebook()
    }

    private func refreshSelection() {
        guard let resolved = selectedNotebook else { return }
        if selectedNotebookId != resolved.id {
            selectedNotebookId = resolved.id
        }
        loadSelectedNotebook()
    }

    private func loadSelectedNotebook() {
        guard let notebook = selectedNotebook else {
            nameDraft = ""
            rulesDraft = ""
            isDefaultDraft = false
            return
        }
        nameDraft = notebook.name
        rulesDraft = notebook.rulesOverrides ?? ""
        isDefaultDraft = notebook.isDefault
    }

    private func addNotebook() {
        let trimmedName = newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Enter a notebook name to continue."
            return
        }

        let notebook = NotebookEntity(context: context)
        notebook.id = UUID()
        notebook.name = trimmedName
        notebook.createdAt = Date()
        notebook.updatedAt = Date()
        if notebooks.first(where: { $0.isDefault }) == nil {
            notebook.isDefault = true
        }

        do {
            try context.save()
            selectedNotebookId = notebook.id
            newNotebookName = ""
            statusMessage = "Notebook added."
            nameDraft = notebook.name
            rulesDraft = ""
            isDefaultDraft = notebook.isDefault
        } catch {
            statusMessage = "Failed to add notebook."
        }
    }

    private func saveSelectedNotebook() {
        guard let notebook = selectedNotebook else { return }
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Notebook name cannot be empty."
            return
        }

        if isDefaultDraft {
            for other in notebooks where other.objectID != notebook.objectID {
                other.isDefault = false
            }
        }

        let trimmedRules = rulesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        notebook.name = trimmedName
        notebook.isDefault = isDefaultDraft
        notebook.rulesOverrides = trimmedRules.isEmpty ? nil : trimmedRules
        notebook.updatedAt = Date()

        do {
            try context.save()
            statusMessage = "Notebook saved."
        } catch {
            statusMessage = "Failed to save notebook."
        }
    }
}

#Preview {
    NotebookPickerView(selectedNotebookId: .constant(nil))
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
