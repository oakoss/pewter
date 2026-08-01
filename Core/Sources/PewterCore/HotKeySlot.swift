import Foundation

/// The app's global hotkeys, enumerated once. Carbon id, defaults key, and
/// display title all hang off this so adding a hotkey touches one place
/// instead of parallel enums in the recorder, the settings, and the center.
public enum HotKeySlot: UInt32, CaseIterable, Sendable {
    case capture = 1
    case panelToggle = 2

    /// On-disk UserDefaults keys — do not rename.
    public var defaultsKey: String {
        switch self {
        case .capture: "captureHotKeyChord"
        case .panelToggle: "panelToggleChord"
        }
    }

    /// Also the referent of the recorder's "Already used by …" hint, so the
    /// row label and the conflict message can't disagree.
    public var title: String {
        switch self {
        case .capture: "Capture selection"
        case .panelToggle: "Show or hide panel"
        }
    }

    /// Settings-row subtitle; lives here so a new hotkey is one enum case,
    /// not another hand-copied settings row.
    public var subtitle: String {
        switch self {
        case .capture: "Works even where the double-tap can't — no Accessibility needed"
        case .panelToggle: "Summons the panel from any app"
        }
    }

    public var armingFailureMessage: String {
        "Couldn't set up the \(title) shortcut — it may be in use by another app"
    }

    /// nil is off. Recorded free-form in the settings window.
    public func chord(in defaults: UserDefaults = .standard) -> KeyChord? {
        KeyChord.load(from: defaults, key: defaultsKey)
    }

    public func setChord(_ chord: KeyChord?, in defaults: UserDefaults = .standard) {
        KeyChord.store(chord, in: defaults, key: defaultsKey)
    }
}
