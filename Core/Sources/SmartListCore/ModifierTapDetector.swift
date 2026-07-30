import Foundation

/// Pure state machine for the double-tap-modifier gesture: two complete
/// press-releases of the target modifier within `window`, with no other key
/// or modifier in between (so typing two capitals never triggers a
/// Shift-configured detector). The AppKit layer feeds it pre-classified
/// events; this type owns all the timing and ordering logic.
public struct ModifierTapDetector: Sendable {
    public enum ModifierEvent: Sendable {
        /// The target modifier is now the only relevant modifier held.
        case targetAlone
        /// No relevant modifiers held.
        case none
        /// Any other modifier combination (a chord, or a different modifier).
        case other(targetHeld: Bool)
    }

    private let window: TimeInterval
    private var targetIsDown = false
    private var tapInProgress = false
    private var previousTapEndedAt: TimeInterval?

    public init(window: TimeInterval = 0.3) {
        self.window = window
    }

    /// Any character key press or mouse click breaks the gesture — a
    /// modifier-click (Cmd-clicking links, Ctrl-click context menus) must
    /// never read as a clean tap.
    public mutating func handleGestureBreak() {
        reset()
    }

    /// Returns true when the gesture completes — on the key-up of the second
    /// tap, so the physical modifier is already released when the caller
    /// synthesizes Cmd+C.
    public mutating func handleModifiers(_ event: ModifierEvent, timestamp: TimeInterval) -> Bool {
        switch event {
        case .targetAlone:
            if !targetIsDown {
                targetIsDown = true
                tapInProgress = true
            }
            return false

        case .none:
            guard targetIsDown else { return false }
            targetIsDown = false
            let completedCleanTap = tapInProgress
            tapInProgress = false

            guard completedCleanTap else { return false }

            if let previous = previousTapEndedAt, timestamp - previous <= window {
                previousTapEndedAt = nil
                return true
            }
            previousTapEndedAt = timestamp
            return false

        case let .other(targetHeld):
            reset()
            targetIsDown = targetHeld
            return false
        }
    }

    private mutating func reset() {
        targetIsDown = false
        tapInProgress = false
        previousTapEndedAt = nil
    }
}
