import Foundation
import PewterCore

/// Panel preferences persisted in UserDefaults; read at action time, so no
/// observation plumbing is needed.
enum PanelSettings {
    private static let listCopyStyleKey = "panelListCopyStyle"
    private static let toggleChordKey = "panelToggleChord"

    static var listCopyStyle: ItemFormatter.ListStyle {
        get {
            UserDefaults.standard.string(forKey: listCopyStyleKey)
                .flatMap(ItemFormatter.ListStyle.init(rawValue:)) ?? .numbered
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: listCopyStyleKey)
        }
    }

    /// nil is off. Recorded free-form in the settings window.
    static var toggleChord: KeyChord? {
        get { KeyChord.load(from: .standard, key: toggleChordKey) }
        set { KeyChord.store(newValue, in: .standard, key: toggleChordKey) }
    }
}

extension ItemFormatter.ListStyle {
    var menuTitle: String {
        switch self {
        case .numbered: "Numbered  1. 2. 3."
        case .bulleted: "Bulleted  - - -"
        case .taskList: "Task List  - [ ]"
        }
    }
}
