import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Binding var isComplete: Bool
    var onImport: () -> Void = {}
    @State private var allowProcessing = false
    @Environment(\.themeColors) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "book.pages")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.accent)
                    .padding(.top, 48)
                Text("Welcome to MarginShot").font(.largeTitle.bold())
                Text("Keep the page. Find the idea.").font(.title2)
                Text("Scan notebook pages or import selected photos. Your originals are saved locally, so you can collect ideas offline.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Processing with Gemini", systemImage: "sparkles").font(.headline)
                    Text("With your permission, page images go to Gemini to create notes. Chat sends your question and selected note text to Gemini; the image choice does not block text requests.")
                    if PresentationDefaults.current.object(forKey: "privacySendImagesToLLM") == nil {
                        Toggle("Process scans with Gemini", isOn: $allowProcessing)
                        Text("Leave this off to keep pages local and pending. You can change it in Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Your existing processing preference is preserved. You can change it in Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text("Backup is optional and stays separate from Gemini processing. Choose a destination later in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Start scanning") {
                    finish()
                    if DesignFixture.current == nil && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .video) { _ in }
                    }
                }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .foregroundStyle(theme.scheme == .dark ? .black : .white)
                Button("Import Photos") { finish(); onImport() }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("Explore the app") { finish() }
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(theme.accent)
    }

    private func finish() {
        ProcessingConsent.initialize(allowImages: allowProcessing, defaults: PresentationDefaults.current)
        isComplete = true
    }
}
