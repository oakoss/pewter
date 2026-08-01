import Foundation
@testable import PewterCore
import Testing

@MainActor
struct HotKeyCoordinatorTests {
    private let chordA = KeyChord(keyCode: 8, modifiers: [.control, .shift])
    private let chordB = KeyChord(keyCode: 35, modifiers: [.control, .option])

    @Test func syncArmsStoredChordsAndPausesForRecording() throws {
        try withTestDefaults { defaults in
            HotKeySlot.capture.setChord(chordA, in: defaults)
            var armed: [HotKeySlot: KeyChord?] = [:]
            var tapActive: Bool?
            let coordinator = HotKeyCoordinator(
                defaults: defaults,
                arm: { slot, chord in
                    armed[slot] = chord
                    return true
                },
                setTapActive: { tapActive = $0 }
            )

            coordinator.syncTriggers()
            #expect(armed[.capture] == chordA)
            #expect(armed[.panelToggle] == KeyChord??.some(nil))
            #expect(tapActive == true)

            coordinator.beginRecording()
            #expect(armed[.capture] == KeyChord??.some(nil))
            #expect(tapActive == false)

            #expect(coordinator.endRecording().isEmpty)
            #expect(armed[.capture] == chordA)
            #expect(tapActive == true)
        }
    }

    @Test func syncRefusalClearsTheStoreAndReportsTheSlot() throws {
        try withTestDefaults { defaults in
            HotKeySlot.capture.setChord(chordA, in: defaults)
            let coordinator = HotKeyCoordinator(
                defaults: defaults,
                arm: { slot, chord in !(slot == .capture && chord != nil) },
                setTapActive: { _ in }
            )

            #expect(coordinator.syncTriggers() == [.capture])
            // Cleared: a stored chord must never display as armed while
            // nothing is registered.
            #expect(HotKeySlot.capture.chord(in: defaults) == nil)
            #expect(coordinator.syncTriggers().isEmpty)
        }
    }

    @Test func assignPersistsAndArms() throws {
        try withTestDefaults { defaults in
            var armed: [HotKeySlot: KeyChord?] = [:]
            let coordinator = HotKeyCoordinator(
                defaults: defaults,
                arm: { slot, chord in
                    armed[slot] = chord
                    return true
                },
                setTapActive: { _ in }
            )

            #expect(coordinator.assign(chordA, to: .capture) == nil)
            #expect(HotKeySlot.capture.chord(in: defaults) == chordA)
            #expect(armed[.capture] == chordA)
        }
    }

    @Test func assignRefusalRestoresThePreviousChord() throws {
        try withTestDefaults { defaults in
            HotKeySlot.capture.setChord(chordA, in: defaults)
            let coordinator = HotKeyCoordinator(
                defaults: defaults,
                arm: { _, chord in chord != chordB },
                setTapActive: { _ in }
            )

            #expect(coordinator.assign(chordB, to: .capture) == "That shortcut is taken by another app")
            #expect(HotKeySlot.capture.chord(in: defaults) == chordA)
        }
    }

    @Test func assignDoubleRefusalClearsTheSlot() throws {
        try withTestDefaults { defaults in
            HotKeySlot.capture.setChord(chordA, in: defaults)
            let coordinator = HotKeyCoordinator(
                defaults: defaults,
                arm: { _, chord in chord == nil },
                setTapActive: { _ in }
            )

            let message = coordinator.assign(chordB, to: .capture)
            #expect(message == "That shortcut is taken — and another app claimed the previous one too")
            #expect(HotKeySlot.capture.chord(in: defaults) == nil)
        }
    }

    @Test func clearWhileRecordingSkipsArmingUntilTheResync() throws {
        try withTestDefaults { defaults in
            HotKeySlot.panelToggle.setChord(chordA, in: defaults)
            var armCalls = 0
            let coordinator = HotKeyCoordinator(
                defaults: defaults,
                arm: { _, _ in
                    armCalls += 1
                    return true
                },
                setTapActive: { _ in }
            )

            coordinator.beginRecording()
            let callsAfterBegin = armCalls
            coordinator.clear(.panelToggle)
            #expect(armCalls == callsAfterBegin)
            #expect(HotKeySlot.panelToggle.chord(in: defaults) == nil)
            #expect(coordinator.endRecording().isEmpty)
        }
    }
}
