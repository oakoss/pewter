@testable import PewterCore

extension MutationOutcome {
    /// What the mutation produced, nil for any other outcome. For tests whose
    /// subject is something *after* the change — undo, merge, search — so
    /// their setup stays one line. A test about the change itself should match
    /// the case, so a refusal can't pass as "nothing to do".
    var product: Value? {
        guard case let .applied(value) = self else { return nil }
        return value
    }
}
