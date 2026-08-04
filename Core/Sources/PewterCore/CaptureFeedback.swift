import Foundation

/// User-facing capture feedback. One value drives every surface — the HUD
/// at the point of capture and the status-item flash VoiceOver reads — so
/// a sighted user and a VoiceOver user never get different stories.
public enum CaptureFeedback: Equatable, Sendable {
    case captured
    case nothingSelected
    case captureFailed

    public var symbolName: String {
        switch self {
        case .captured: "checkmark.circle"
        case .nothingSelected: "xmark.circle"
        case .captureFailed: "exclamationmark.circle"
        }
    }

    public var message: String {
        switch self {
        case .captured: "Captured"
        case .nothingSelected: "No text selected"
        case .captureFailed: "Couldn't capture — try copying manually"
        }
    }

    /// Failure text is an instruction the user has to read and act on; it
    /// stays up longer than the success confirmation.
    public var duration: TimeInterval {
        switch self {
        case .captured: 1.2
        case .nothingSelected, .captureFailed: 2
        }
    }

    /// Name of the system sound that carries this outcome to a VoiceOver
    /// user. Capture fires while another app is frontmost, and macOS speaks
    /// accessibility announcements only for the frontmost app, so the
    /// spoken outcome never arrives; a sound reaches the user regardless of
    /// who is frontmost and doesn't cut across whatever VoiceOver is
    /// currently reading. Distinct per outcome — telling them apart by ear
    /// is the whole point.
    public var soundName: String {
        switch self {
        case .captured: "Pop"
        case .nothingSelected: "Tink"
        case .captureFailed: "Basso"
        }
    }
}
