import Foundation
@testable import PewterCore
import Testing

struct ModifierTapDetectorTests {
    @Test func twoQuickTapsFire() {
        var detector = ModifierTapDetector()
        #expect(detector.handleModifiers(.targetAlone, timestamp: 0.00) == false)
        #expect(detector.handleModifiers(.none, timestamp: 0.05) == false)
        #expect(detector.handleModifiers(.targetAlone, timestamp: 0.10) == false)
        #expect(detector.handleModifiers(.none, timestamp: 0.15) == true)
    }

    @Test func slowTapsDoNotFire() {
        var detector = ModifierTapDetector(window: 0.3)
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.0)
        _ = detector.handleModifiers(.none, timestamp: 0.1)
        _ = detector.handleModifiers(.targetAlone, timestamp: 1.0)
        #expect(detector.handleModifiers(.none, timestamp: 1.1) == false)
    }

    @Test func typingCapitalsDoesNotFire() {
        var detector = ModifierTapDetector()
        // Shift down, letter typed (keyDown), shift up — twice quickly.
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.00)
        detector.handleGestureBreak()
        _ = detector.handleModifiers(.none, timestamp: 0.05)
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.10)
        detector.handleGestureBreak()
        #expect(detector.handleModifiers(.none, timestamp: 0.15) == false)
    }

    @Test func chordShortcutsDoNotFire() {
        var detector = ModifierTapDetector()
        // Cmd+Shift+S style chord: shift joins other modifiers.
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.00)
        _ = detector.handleModifiers(.other(targetHeld: true), timestamp: 0.02)
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.04)
        #expect(detector.handleModifiers(.none, timestamp: 0.06) == false)
        // A clean double-tap afterwards still works.
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.20)
        _ = detector.handleModifiers(.none, timestamp: 0.25)
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.30)
        #expect(detector.handleModifiers(.none, timestamp: 0.35) == true)
    }

    @Test func modifierClicksDoNotCompleteTheGesture() {
        var detector = ModifierTapDetector()
        // Cmd-click, Cmd-click in quick succession: modifier down, click
        // (gesture break), modifier up — twice within the window.
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.00)
        detector.handleGestureBreak()
        _ = detector.handleModifiers(.none, timestamp: 0.05)
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.10)
        detector.handleGestureBreak()
        #expect(detector.handleModifiers(.none, timestamp: 0.15) == false)
    }

    @Test func thirdTapNeedsAFreshPair() {
        var detector = ModifierTapDetector()
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.00)
        _ = detector.handleModifiers(.none, timestamp: 0.05)
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.10)
        #expect(detector.handleModifiers(.none, timestamp: 0.15) == true)
        // The pair consumed both taps; a third tap alone must not fire.
        _ = detector.handleModifiers(.targetAlone, timestamp: 0.20)
        #expect(detector.handleModifiers(.none, timestamp: 0.25) == false)
    }
}
