import Foundation

enum CameraSessionState: Equatable {
    case idle, configuring, ready, unavailable, interrupted, failed

    var canRetry: Bool { self == .interrupted || self == .failed }
    var title: String {
        switch self {
        case .idle: return "Camera paused"
        case .configuring: return "Preparing camera…"
        case .ready: return "Ready to scan"
        case .unavailable: return "Camera unavailable"
        case .interrupted: return "Camera interrupted"
        case .failed: return "Camera needs attention"
        }
    }
    var detail: String {
        switch self {
        case .ready: return "Point at a notebook page."
        case .unavailable: return "Import selected photos to add pages on this device."
        case .interrupted: return "Another activity interrupted the camera. Try again when it ends, or import photos."
        case .failed: return "The camera could not start. Try again, or import selected photos."
        default: return "Your saved pages are safe. You can also import selected photos."
        }
    }
}

enum ProcessingConsent {
    /// Only initialize a previously unrecorded choice. Onboarding replay never changes it.
    static func initialize(allowImages: Bool, defaults: UserDefaults) {
        guard defaults.object(forKey: "privacySendImagesToLLM") == nil else { return }
        defaults.set(allowImages, forKey: "privacySendImagesToLLM")
    }
}
