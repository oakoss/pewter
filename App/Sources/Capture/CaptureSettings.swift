import AppKit
import Carbon.HIToolbox

/// User-configurable capture triggers, persisted in UserDefaults. The
/// double-tap modifier is configurable because tools like Karabiner's
/// SpaceCadet rule make Shift taps type "(" — those users need Control or
/// Option instead, or the chord hotkey.
enum CaptureSettings {
    enum TapModifier: String, CaseIterable {
        case shift, control, option, command

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .shift: .shift
            case .control: .control
            case .option: .option
            case .command: .command
            }
        }

        var menuTitle: String {
            switch self {
            case .shift: "Double-tap ⇧ Shift"
            case .control: "Double-tap ⌃ Control"
            case .option: "Double-tap ⌥ Option"
            case .command: "Double-tap ⌘ Command"
            }
        }

        var hint: String {
            switch self {
            case .shift: "Double-tap Shift to capture a selection"
            case .control: "Double-tap Control to capture a selection"
            case .option: "Double-tap Option to capture a selection"
            case .command: "Double-tap Command to capture a selection"
            }
        }
    }

    enum ChordHotKey: String, CaseIterable {
        case off
        case controlShiftC
        case controlOptionC

        var menuTitle: String {
            switch self {
            case .off: "Off"
            case .controlShiftC: "⌃⇧C"
            case .controlOptionC: "⌃⌥C"
            }
        }

        /// Carbon (keyCode, modifiers) for RegisterEventHotKey.
        var carbonKey: (keyCode: UInt32, modifiers: UInt32)? {
            switch self {
            case .off: nil
            case .controlShiftC: (UInt32(kVK_ANSI_C), UInt32(controlKey | shiftKey))
            case .controlOptionC: (UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey))
            }
        }
    }

    private static let tapModifierKey = "captureTapModifier"
    private static let chordHotKeyKey = "captureChordHotKey"

    static var tapModifier: TapModifier {
        get {
            UserDefaults.standard.string(forKey: tapModifierKey)
                .flatMap(TapModifier.init(rawValue:)) ?? .shift
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: tapModifierKey)
        }
    }

    static var chordHotKey: ChordHotKey {
        get {
            UserDefaults.standard.string(forKey: chordHotKeyKey)
                .flatMap(ChordHotKey.init(rawValue:)) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: chordHotKeyKey)
        }
    }
}
