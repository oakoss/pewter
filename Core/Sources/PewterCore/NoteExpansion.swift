import Foundation

/// Which notes show their full text instead of the row's line clamp.
/// Transient by design — expansion is a reading aid, not document state, so
/// it never persists to the file and survives filtering (a search hiding an
/// expanded note must not collapse it). Stale IDs from deleted notes are
/// harmless: IDs are never reused, so they can never match a row again.
public struct NoteExpansion: Equatable, Sendable {
    private var expanded: Set<UUID> = []

    public init() {}

    public func isExpanded(_ id: UUID) -> Bool {
        expanded.contains(id)
    }

    /// Uniform toggle over a selection: any collapsed target expands them
    /// all; only a fully expanded selection collapses. A mixed selection
    /// becoming fully expanded first means Cmd-E never hides text the user
    /// hasn't seen yet. An empty selection is a no-op. Returns whether the
    /// toggle collapsed — callers repairing scroll position need the
    /// direction, and answering here keeps the rule in one place.
    @discardableResult
    public mutating func toggle(_ ids: Set<UUID>) -> Bool {
        if ids.isSubset(of: expanded) {
            expanded.subtract(ids)
            return !ids.isEmpty
        }
        expanded.formUnion(ids)
        return false
    }
}
