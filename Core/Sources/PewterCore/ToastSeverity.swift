import Foundation

/// What a panel toast means. The same neutral capsule carried outcomes with
/// opposite meanings — a confirmation and a refusal that cost the user the
/// note they had typed looked identical — so the meaning is a value the toast
/// carries rather than a tone the caller hopes reads correctly.
public enum ToastSeverity: Equatable, Sendable, CaseIterable {
    /// It happened. The note landed, the diagnostics copied.
    case confirmation
    /// Something didn't work, but nothing the user typed was lost.
    case warning
    /// The user's input was rejected and is not stored.
    case refusal

    /// Leading SF Symbol. A shape, not only a tint — the panel is translucent
    /// and colour alone would be the one signal a low-contrast display or a
    /// colour-blind user loses, which is the same reason the capture HUD
    /// carries a symbol.
    public var symbolName: String {
        switch self {
        case .confirmation: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .refusal: "exclamationmark.triangle.fill"
        }
    }

    /// How long it stays up. A refusal is an instruction to re-read and act
    /// on; a confirmation has been absorbed by the time it fades.
    public var duration: Duration {
        switch self {
        case .confirmation: .seconds(2)
        case .warning: .seconds(3)
        case .refusal: .seconds(4)
        }
    }
}
