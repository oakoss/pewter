import Foundation
import PewterCore

/// Panel preferences persisted in UserDefaults; read at action time, so no
/// observation plumbing is needed.
enum PanelSettings {
    private static let listCopyStyleKey = "panelListCopyStyle"

    static var listCopyStyle: ItemFormatter.ListStyle {
        get {
            UserDefaults.standard.string(forKey: listCopyStyleKey)
                .flatMap(ItemFormatter.ListStyle.init(rawValue:)) ?? .numbered
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: listCopyStyleKey)
        }
    }
}

extension ItemFormatter.ListStyle {
    var title: String {
        switch self {
        case .numbered: "Numbered  1. 2. 3."
        case .bulleted: "Bulleted  - - -"
        case .taskList: "Task List  - [ ]"
        }
    }
}
