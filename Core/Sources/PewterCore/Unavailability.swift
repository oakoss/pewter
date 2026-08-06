import Foundation

/// Why the notes file can't be read. Structured rather than a bare string
/// because the remedy differs per cause, and every surface that reports the
/// problem has to name which repair applies — a user sent to check
/// permissions on a file that is merely mis-encoded debugs the wrong thing.
public enum UnreadableCause: Equatable, Sendable {
    /// The file is there but the app is not allowed to open it.
    case notPermitted
    /// Readable bytes that aren't UTF-8.
    case notUTF8
    /// Anything else, carrying the system's description for diagnostics.
    /// Its remedy is necessarily generic — that is the honest answer, not a
    /// gap to be filled with a guess.
    case other(String)

    /// Classifies a read error. Only the permission case earns its own arm:
    /// it is the one failure with a repair the user can name, and every other
    /// errno maps to advice we would be inventing.
    ///
    /// Both spellings are matched — `Data(contentsOf:)` usually bridges to
    /// `CocoaError`, but a raw `POSIXError` reaches here from some volumes,
    /// and falling to `.other` there costs the user the one specific remedy
    /// this type exists to name.
    public init(readError: Error) {
        switch readError {
        case let cocoa as CocoaError where cocoa.code == .fileReadNoPermission:
            self = .notPermitted
        case let posix as POSIXError where posix.code == .EACCES || posix.code == .EPERM:
            self = .notPermitted
        default:
            self = .other(readError.localizedDescription)
        }
    }

    /// Cause phrase for a log line. The named arms are fixed strings; `.other`
    /// carries a system description, which can include the file's name but
    /// never note or clipboard content.
    public var logDescription: String {
        switch self {
        case .notPermitted: "no permission to read it"
        case .notUTF8: "not valid UTF-8"
        case let .other(reason): reason
        }
    }
}

/// Why a note accepted right now would not reach disk.
///
/// The two arms need opposite remedies, which is the whole reason this is a
/// vocabulary rather than a Bool: an unreadable file is a repair the user must
/// go and make, while an in-flight adoption clears itself on the next turn and
/// the only useful instruction is to try again.
public enum Unavailability: Equatable, Sendable {
    case unreadable(cause: UnreadableCause)
    /// A document read from disk has been adopted but not yet delivered to the
    /// store, so anything accepted now is replaced when it lands. The file
    /// itself is perfectly readable and health reads `.ok`.
    case adoptionInFlight

    /// Cause phrase for a log line, so a diagnostics report can tell a broken
    /// file from a handoff window that would have cleared on its own.
    public var logDescription: String {
        switch self {
        case let .unreadable(cause): "the notes file can't be read (\(cause.logDescription))"
        case .adoptionInFlight: "an adopted document is still in flight"
        }
    }

    /// Refusal text for a surface the user is looking at — the panel's
    /// composer toast. Worded for a composer rather than a capture, but it
    /// names the same repair the HUD does for the same cause, which is the
    /// part a user would notice disagreeing.
    public var refusalMessage: String {
        switch self {
        case .unreadable(.notPermitted):
            "Can't save — check your notes file's permissions"
        case .unreadable(.notUTF8):
            "Can't save — re-save your notes file as UTF-8"
        case .unreadable(.other):
            "Can't save — your notes file can't be read"
        case .adoptionInFlight:
            "Your notes just changed on disk — try again"
        }
    }
}
