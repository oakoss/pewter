import Foundation

/// User-facing capture feedback. One value drives every surface — the HUD
/// at the point of capture and the status-item flash VoiceOver reads — so
/// a sighted user and a VoiceOver user never get different stories.
public enum CaptureFeedback: Equatable, Sendable {
    case captured
    case nothingSelected
    case captureFailed
    /// The text was read fine but had nowhere to go. Distinct from
    /// `captureFailed`: the user's remedy is the file or a second attempt,
    /// not the selection. Which of those it is comes from the reason.
    case notesUnavailable(Unavailability)

    public var symbolName: String {
        switch self {
        case .captured: "checkmark.circle"
        case .nothingSelected: "xmark.circle"
        case .captureFailed: "exclamationmark.circle"
        // A handoff window is a "try that again", not a fault: the arrows say
        // so without the alarm a warning triangle carries.
        case .notesUnavailable(.adoptionInFlight): "arrow.triangle.2.circlepath"
        case .notesUnavailable(.unreadable): "exclamationmark.triangle"
        }
    }

    public var message: String {
        switch self {
        case .captured: "Captured"
        case .nothingSelected: "No text selected"
        case .captureFailed: "Couldn't capture — try copying manually"
        // Each names the repair that applies.
        case .notesUnavailable(.unreadable(.notPermitted)):
            "Can't read your notes file — check its permissions"
        case .notesUnavailable(.unreadable(.notUTF8)):
            "Can't read your notes file — re-save it as UTF-8"
        // No arm to name: the cause is whatever the system reported, and
        // inventing a repair for it would be worse than admitting there
        // isn't a specific one.
        case .notesUnavailable(.unreadable(.other)):
            "Can't read your notes file — nothing was saved"
        case .notesUnavailable(.adoptionInFlight):
            "Your notes just changed on disk — capture again"
        }
    }

    /// Failure text is an instruction the user has to read and act on; it
    /// stays up longer than the success confirmation.
    public var duration: TimeInterval {
        switch self {
        case .captured: 1.2
        case .nothingSelected, .captureFailed, .notesUnavailable: 2
        }
    }

    /// Name of the system sound that carries this outcome to a VoiceOver
    /// user. Capture fires while another app is frontmost, and macOS speaks
    /// accessibility announcements only for the frontmost app, so the
    /// spoken outcome never arrives; a sound reaches the user regardless of
    /// who is frontmost and doesn't cut across whatever VoiceOver is
    /// currently reading. Distinct per outcome — telling them apart by ear
    /// is the whole point.
    ///
    /// The unreadable causes share one: they differ in which repair to make,
    /// which is what the message is for, and a user who can't tell two alerts
    /// apart is no worse off than one who hears a single "your file is broken".
    public var soundName: String {
        switch self {
        case .captured: "Pop"
        case .nothingSelected: "Tink"
        case .captureFailed: "Basso"
        case .notesUnavailable(.unreadable): "Sosumi"
        case .notesUnavailable(.adoptionInFlight): "Submarine"
        }
    }
}
