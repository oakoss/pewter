@testable import PewterCore

extension ListStore.AddResult {
    /// The added item, nil for any other outcome. For tests whose subject is
    /// something *after* the add — undo, merge, search — so their setup stays
    /// one line. A test about the add itself should match the case, so a
    /// refusal can't pass as "nothing to add".
    var item: Item? {
        guard case let .added(item) = self else { return nil }
        return item
    }
}
