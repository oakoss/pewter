/// What became of a change to the notes.
///
/// Three outcomes rather than an optional product, because "there was nothing
/// to do" and "it would not have reached disk" call for opposite responses —
/// silence for the first, a named repair for the second — and an absence
/// conflates them into "nothing happened", which is how a user's change goes
/// missing with every surface reporting success.
///
/// `Value` is whatever the mutation produced: the note it added, the notes it
/// removed, the note a merge left behind. Mutations whose product no caller
/// needs still carry one, so the vocabulary stays single.
///
/// The conformances are conditional rather than constraints on `Value`, so a
/// future payload that is neither `Equatable` nor `Sendable` is expressible
/// without reshaping every mutation that already works.
public enum MutationOutcome<Value> {
    case applied(Value)
    /// There was nothing for the call to do: the input was vacuous, its target
    /// isn't there, or the document already said what was asked. Nothing was
    /// written and nothing is wrong.
    case unchanged
    /// The change was fine but would not have reached disk, so it was not
    /// made. The document is exactly as it was.
    case refused(Unavailability)
}

extension MutationOutcome: Equatable where Value: Equatable {}

extension MutationOutcome: Sendable where Value: Sendable {}
