import SwiftUI

struct CaptureView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray6), Color(.systemGray5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()
                Text("Scanner Ready")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Capture notebook pages quickly.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button(action: {}) {
                    Text("Scan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
                HStack(spacing: 12) {
                    Text("Batch: On")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Inbox: 0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
    }
}

#Preview {
    CaptureView()
}
