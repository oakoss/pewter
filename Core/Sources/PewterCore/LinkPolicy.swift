import Foundation

/// Schemes a link may carry to be written as a link or opened from the
/// panel. One list for both ends: anything else (javascript:, data:,
/// file:, …) drops to plain text at capture and never becomes clickable
/// in a hand-edited note.
public enum LinkPolicy {
    public static let safeSchemes: Set<String> = ["http", "https", "mailto"]

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        return safeSchemes.contains(scheme.lowercased())
    }
}
