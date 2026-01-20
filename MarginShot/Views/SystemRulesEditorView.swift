import SwiftUI

struct SystemRulesEditorView: View {
    @State private var rulesText = ""
    @State private var originalRules = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $rulesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
            } footer: {
                Text("Stored at vault/_system/SYSTEM.md. Rules are appended to prompts during processing and chat.")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reset to Defaults") {
                rulesText = SystemRulesStore.defaultRules
                statusMessage = "Defaults loaded. Save to apply."
            }
        }
        .navigationTitle("System Rules")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveRules()
                }
                .disabled(rulesText == originalRules)
            }
        }
        .onAppear {
            loadRules()
        }
    }

    private func loadRules() {
        let rules = SystemRulesStore.load()
        rulesText = rules
        originalRules = rules
        statusMessage = nil
    }

    private func saveRules() {
        do {
            try SystemRulesStore.save(rulesText)
            originalRules = rulesText
            statusMessage = "System rules saved."
        } catch {
            statusMessage = "Failed to save system rules."
        }
    }
}

#Preview {
    NavigationStack {
        SystemRulesEditorView()
    }
}
