import SwiftUI
import AVFoundation
import Photos
import UIKit

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var step: OnboardingStep = .welcome
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray6), Color(.systemGray5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()
                Text(step.title)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text(step.subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                if step == .permissions {
                    permissionRow(
                        title: "Camera",
                        detail: cameraDetail,
                        buttonTitle: cameraButtonTitle,
                        isEnabled: cameraStatus == .notDetermined,
                        action: requestCameraAccess
                    )
                    permissionRow(
                        title: "Photos (Optional)",
                        detail: photoDetail,
                        buttonTitle: photoButtonTitle,
                        isEnabled: photoStatus == .notDetermined,
                        action: requestPhotoAccess
                    )
                    if cameraStatus == .denied || cameraStatus == .restricted {
                        Text("Camera access is required to scan pages. Enable it in Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Open Settings", action: openSettings)
                            .buttonStyle(.bordered)
                    }
                }
                Spacer()
                Button(step.primaryButtonTitle) {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(step == .permissions && !cameraIsAuthorized)
                if step == .permissions {
                    Text("Photos access is optional and can be enabled later.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
        .onAppear(perform: refreshStatuses)
        .onChange(of: step) { newValue in
            if newValue == .permissions {
                refreshStatuses()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshStatuses()
        }
    }

    private var cameraIsAuthorized: Bool {
        cameraStatus == .authorized
    }

    private var cameraDetail: String {
        switch cameraStatus {
        case .authorized:
            return "Ready to scan."
        case .denied, .restricted:
            return "Access blocked."
        case .notDetermined:
            return "Needed for scanning pages."
        @unknown default:
            return "Check access."
        }
    }

    private var photoDetail: String {
        switch photoStatus {
        case .authorized, .limited:
            return "Import from your library."
        case .denied, .restricted:
            return "Access blocked."
        case .notDetermined:
            return "Optional for importing."
        @unknown default:
            return "Check access."
        }
    }

    private var cameraButtonTitle: String {
        switch cameraStatus {
        case .authorized:
            return "Enabled"
        case .denied, .restricted:
            return "Blocked"
        case .notDetermined:
            return "Enable"
        @unknown default:
            return "Enable"
        }
    }

    private var photoButtonTitle: String {
        switch photoStatus {
        case .authorized, .limited:
            return "Enabled"
        case .denied, .restricted:
            return "Blocked"
        case .notDetermined:
            return "Enable"
        @unknown default:
            return "Enable"
        }
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .permissions
        case .permissions:
            isComplete = true
        }
    }

    private func refreshStatuses() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                refreshStatuses()
            }
        }
    }

    private func requestPhotoAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            DispatchQueue.main.async {
                refreshStatuses()
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        buttonTitle: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private enum OnboardingStep {
    case welcome
    case permissions

    var title: String {
        switch self {
        case .welcome:
            return "Welcome to MarginShot"
        case .permissions:
            return "Enable Access"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "Snap notebook pages and chat with them later. Notes stay local until you enable sync."
        case .permissions:
            return "We use the camera for scanning and photos for optional imports."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .welcome:
            return "Get Started"
        case .permissions:
            return "Continue"
        }
    }
}

#Preview {
    OnboardingView(isComplete: .constant(false))
}
