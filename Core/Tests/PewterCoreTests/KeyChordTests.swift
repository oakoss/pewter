import Foundation
@testable import PewterCore
import Testing

struct KeyChordTests {
    @Test func displayOrdersModifiersControlOptionShiftCommand() {
        let chord = KeyChord(keyCode: 35, modifiers: [.command, .shift, .option, .control])
        #expect(chord.display == "⌃⌥⇧⌘P")
    }

    @Test func displayNamesSpecialKeys() {
        #expect(KeyChord(keyCode: 49, modifiers: [.control, .shift]).display == "⌃⇧Space")
        #expect(KeyChord(keyCode: 126, modifiers: [.option]).display == "⌥↑")
        #expect(KeyChord(keyCode: 96, modifiers: []).display == "F5")
    }

    @Test func unknownKeyCodeFallsBackToNumericName() {
        let chord = KeyChord(keyCode: 200, modifiers: [.command])
        #expect(chord.display == "⌘key 200")
    }

    @Test func validationRequiresAChordingModifier() {
        #expect(KeyChord(keyCode: 35, modifiers: [.control]).isValidGlobalHotKey)
        #expect(KeyChord(keyCode: 35, modifiers: [.option, .shift]).isValidGlobalHotKey)
        #expect(KeyChord(keyCode: 35, modifiers: [.command]).isValidGlobalHotKey)
        #expect(!KeyChord(keyCode: 35, modifiers: []).isValidGlobalHotKey)
        #expect(!KeyChord(keyCode: 35, modifiers: [.shift]).isValidGlobalHotKey)
    }

    @Test func storeAndLoadRoundTrips() throws {
        try withTestDefaults { defaults in
            let chord = KeyChord(keyCode: 49, modifiers: [.control, .shift])

            KeyChord.store(chord, in: defaults, key: "chord")
            #expect(KeyChord.load(from: defaults, key: "chord") == chord)

            KeyChord.store(nil, in: defaults, key: "chord")
            #expect(KeyChord.load(from: defaults, key: "chord") == nil)
        }
    }

    @Test func loadToleratesGarbageData() throws {
        try withTestDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: "chord")
            #expect(KeyChord.load(from: defaults, key: "chord") == nil)
        }
    }

    @Test func loadRejectsInvalidGlobalHotKeys() throws {
        try withTestDefaults { defaults in
            // A decodable but shift-only chord must degrade to off, not arm
            // a chord that shadows typing.
            defaults.set(Data(#"{"keyCode":35,"modifiers":4}"#.utf8), forKey: "chord")
            #expect(KeyChord.load(from: defaults, key: "chord") == nil)
        }
    }

    @Test func persistedWireFormatIsPinned() throws {
        // {"keyCode":N,"modifiers":M} with modifiers as a bare Int is an
        // on-disk format; a change here orphans every stored hotkey.
        let decoded = try JSONDecoder().decode(KeyChord.self, from: Data(#"{"keyCode":35,"modifiers":5}"#.utf8))
        #expect(decoded == KeyChord(keyCode: 35, modifiers: [.control, .shift]))

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(KeyChord(keyCode: 35, modifiers: [.control, .shift]))
        ) as? [String: Int]
        #expect(encoded == ["keyCode": 35, "modifiers": 5])
    }

    @Test func modifierBitValuesArePinned() {
        #expect(KeyChord.Modifiers.control.rawValue == 1)
        #expect(KeyChord.Modifiers.option.rawValue == 2)
        #expect(KeyChord.Modifiers.shift.rawValue == 4)
        #expect(KeyChord.Modifiers.command.rawValue == 8)
    }

    @Test func systemReservedChordsAreDetected() throws {
        // Cmd-Q, Cmd-C, Cmd-Space: every command-only chord is reserved
        for keyCode in [UInt16(12), 8, 49] {
            #expect(KeyChord(keyCode: keyCode, modifiers: .command).isSystemReserved)
        }
        // Cmd-Shift-Tab (reverse app switching)
        #expect(KeyChord(keyCode: 48, modifiers: [.command, .shift]).isSystemReserved)
        #expect(!KeyChord(keyCode: 12, modifiers: [.command, .shift]).isSystemReserved)
        #expect(!KeyChord(keyCode: 8, modifiers: [.control, .command]).isSystemReserved)

        try withTestDefaults { defaults in
            defaults.set(Data(#"{"keyCode":12,"modifiers":8}"#.utf8), forKey: "chord")
            #expect(KeyChord.load(from: defaults, key: "chord") == nil)
        }
    }

    @Test func escapeAndKeypadKeysHaveNames() {
        #expect(KeyChord(keyCode: 53, modifiers: [.control, .option]).display == "⌃⌥Esc")
        #expect(KeyChord(keyCode: 87, modifiers: [.command]).display == "⌘Keypad 5")
    }
}
