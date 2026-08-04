/// Decision rules the panel's keyboard paths share — pure functions over
/// values, so the Esc ladder and copy-scope rules are unit-tested here
/// instead of being exercised only through the view.
public enum PanelCommands {
    public enum EscapeAction: Equatable, Sendable {
        case closeGuide
        case clearSelection
        case clearFilter
        /// Nothing left to unwind — the key falls through to the panel,
        /// which hides.
        case hidePanel
    }

    /// A single selection doesn't count toward the ladder — quick-add
    /// selects what it added, and capture-then-Esc must still hide the
    /// panel in one press.
    public static func escapeAction(
        guideShowing: Bool,
        selectionIsMultiple: Bool,
        filterActive: Bool
    ) -> EscapeAction {
        if guideShowing {
            return .closeGuide
        }
        if selectionIsMultiple {
            return .clearSelection
        }
        if filterActive {
            return .clearFilter
        }
        return .hidePanel
    }

    /// Both inputs are visible projections — the selection an action reads
    /// is always the rows on screen, never raw IDs.
    public static func listCopyTargets(selected: [Item], visible: [Item]) -> [Item] {
        selected.count > 1 ? selected : visible
    }
}
