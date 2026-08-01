import AppKit
import PewterCore

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

    private static let tapModifierKey = "captureTapModifier"
    private static let captureChordKey = "captureHotKeyChord"

    static var tapModifier: TapModifier {
        get {
            UserDefaults.standard.string(forKey: tapModifierKey)
                .flatMap(TapModifier.init(rawValue:)) ?? .shift
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: tapModifierKey)
        }
    }

    /// nil is off. Recorded free-form in the settings window.
    static var captureChord: KeyChord? {
        get { KeyChord.load(from: .standard, key: captureChordKey) }
        set { KeyChord.store(newValue, in: .standard, key: captureChordKey) }
    }
}
