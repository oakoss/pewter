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
}
