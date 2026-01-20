import SwiftUI

struct ChatView: View {
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
                Text("Ask about your notes")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Your captures will appear here once processed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button(action: {}) {
                    Text("Ask")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
                Text("Used sources are hidden until expanded.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(24)
        }
    }
}

#Preview {
    ChatView()
}
