import Foundation
@testable import PewterCore
import Testing

struct RecorderArbiterTests {
    private let assigned: [HotKeySlot: KeyChord] = [
        .panelToggle: KeyChord(keyCode: 35, modifiers: [.control, .shift]),
    ]

    @Test func bareEscapeCancels() {
        let decision = RecorderArbiter.decide(
            KeyChord(keyCode: KeyChord.escapeKeyCode, modifiers: []),
            for: .capture,
            assignments: assigned
        )
        #expect(decision == .cancel)
    }

    @Test func modifiedEscapeIsARecordablePick() {
        let chord = KeyChord(keyCode: KeyChord.escapeKeyCode, modifiers: [.control, .option])
        #expect(RecorderArbiter.decide(chord, for: .capture, assignments: assigned) == .assign(chord))
    }

    @Test func bareAndShiftOnlyKeysAreRejected() {
        for modifiers in [KeyChord.Modifiers(), .shift] {
            let decision = RecorderArbiter.decide(
                KeyChord(keyCode: 8, modifiers: modifiers),
                for: .capture,
                assignments: assigned
            )
            #expect(decision == .reject(hint: "Include ⌃, ⌥, or ⌘ — a bare key would shadow normal typing"))
        }
    }

    @Test func systemReservedChordsAreRejectedWithDisplay() {
        let decision = RecorderArbiter.decide(
            KeyChord(keyCode: 12, modifiers: .command),
            for: .capture,
            assignments: assigned
        )
        #expect(decision == .reject(hint: "⌘Q would shadow a standard shortcut — add another modifier"))
    }

    @Test func crossSlotConflictNamesTheOtherSlot() {
        let decision = RecorderArbiter.decide(
            KeyChord(keyCode: 35, modifiers: [.control, .shift]),
            for: .capture,
            assignments: assigned
        )
        #expect(decision == .reject(hint: "Already used by Show or hide panel"))
    }

    @Test func reRecordingASlotsOwnChordAssigns() {
        // The slot's own current chord is not a conflict with itself.
        let chord = KeyChord(keyCode: 35, modifiers: [.control, .shift])
        #expect(RecorderArbiter.decide(chord, for: .panelToggle, assignments: assigned) == .assign(chord))
    }

    @Test func validChordAssigns() {
        let chord = KeyChord(keyCode: 8, modifiers: [.control, .option])
        #expect(RecorderArbiter.decide(chord, for: .capture, assignments: [:]) == .assign(chord))
    }
}
