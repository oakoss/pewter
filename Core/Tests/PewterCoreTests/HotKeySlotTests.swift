import Foundation
@testable import PewterCore
import Testing

struct HotKeySlotTests {
    @Test func defaultsKeysArePinned() {
        // On-disk keys — a change here orphans every stored hotkey.
        #expect(HotKeySlot.capture.defaultsKey == "captureHotKeyChord")
        #expect(HotKeySlot.panelToggle.defaultsKey == "panelToggleChord")
    }

    @Test func carbonIDsArePinned() {
        #expect(HotKeySlot.capture.rawValue == 1)
        #expect(HotKeySlot.panelToggle.rawValue == 2)
    }

    @Test func chordStorageRoundTrips() throws {
        try withTestDefaults { defaults in
            let chord = KeyChord(keyCode: 35, modifiers: [.control, .shift])

            HotKeySlot.capture.setChord(chord, in: defaults)
            #expect(HotKeySlot.capture.chord(in: defaults) == chord)
            #expect(HotKeySlot.panelToggle.chord(in: defaults) == nil)

            HotKeySlot.capture.setChord(nil, in: defaults)
            #expect(HotKeySlot.capture.chord(in: defaults) == nil)
        }
    }
}
