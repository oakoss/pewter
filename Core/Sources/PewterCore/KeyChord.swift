import Foundation

/// A recordable global hotkey: a key plus its chording modifiers, kept
/// AppKit-free so formatting, validation, and persistence are testable.
public struct KeyChord: Codable, Equatable, Sendable {
    /// Bit values are persisted in UserDefaults via Codable — do not
    /// renumber.
    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// kVK codes referenced by name in logic (the display table below
    /// keeps its literals — it *is* the name mapping).
    public static let escapeKeyCode: UInt16 = 53
    public static let tabKeyCode: UInt16 = 48

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A global hotkey needs a real chording modifier — a bare key or a
    /// shift-only chord would shadow ordinary typing system-wide.
    public var isValidGlobalHotKey: Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    /// Carbon registration wins over normal key dispatch. Every ⌘-only
    /// chord shadows a standard shortcut somewhere — ⌘Q, ⌘W, ⌘Space, and
    /// every app's menu equivalents (⌘C, ⌘S, …) — so require a second
    /// modifier alongside ⌘. ⌘⇧Tab is reverse app switching.
    public var isSystemReserved: Bool {
        modifiers == .command || (modifiers == [.command, .shift] && keyCode == Self.tabKeyCode)
    }

    /// Menu-bar style rendering, e.g. "⌃⇧P" — modifiers in the standard
    /// macOS order (control, option, shift, command).
    public var display: String {
        var symbols = ""
        if modifiers.contains(.control) {
            symbols += "⌃"
        }
        if modifiers.contains(.option) {
            symbols += "⌥"
        }
        if modifiers.contains(.shift) {
            symbols += "⇧"
        }
        if modifiers.contains(.command) {
            symbols += "⌘"
        }
        return symbols + keyName
    }

    public var keyName: String {
        Self.keyNames[keyCode] ?? "key \(keyCode)"
    }

    // MARK: - Persistence

    /// Semantically invalid persisted chords (hand-edited plist, format
    /// drift) degrade to nil — hotkey off — instead of arming a chord that
    /// would shadow typing.
    public static func load(from defaults: UserDefaults, key: String) -> KeyChord? {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(KeyChord.self, from: $0) }
            .flatMap { $0.isValidGlobalHotKey && !$0.isSystemReserved ? $0 : nil }
    }

    public static func store(_ chord: KeyChord?, in defaults: UserDefaults, key: String) {
        if let chord, let data = try? JSONEncoder().encode(chord) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Key names

    /// ANSI virtual key codes (Carbon kVK_* values, stable since classic
    /// Mac OS). Names assume the ANSI/US layout — a non-ANSI layout can
    /// show a different letter than the keycap. Unlisted codes fall back to
    /// a numeric name rather than being unrecordable.
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9",
        26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 76: "Enter",
        117: "Forward Delete", 115: "Home", 119: "End", 116: "Page Up",
        121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        53: "Esc",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 71: "Keypad Clear", 75: "Keypad /", 78: "Keypad -",
        81: "Keypad =",
    ]
}
