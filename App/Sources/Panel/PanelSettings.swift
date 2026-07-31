import Carbon.HIToolbox
import Foundation
import PewterCore

/// Panel preferences persisted in UserDefaults; read at action time, so no
/// observation plumbing is needed.
enum PanelSettings {
    /// Global show/hide hotkey. Chords are disjoint from the capture
    /// hotkey's C-based options so the two settings can't collide.
    enum ToggleHotKey: String, CaseIterable {
        case off
        case controlShiftP
        case controlOptionP
        case controlShiftSpace

        var menuTitle: String {
            switch self {
            case .off: "Off"
            case .controlShiftP: "⌃⇧P"
            case .controlOptionP: "⌃⌥P"
            case .controlShiftSpace: "⌃⇧Space"
            }
        }

        var chord: HotKeyCenter.Chord? {
            switch self {
            case .off: nil
            case .controlShiftP: .init(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | shiftKey))
            case .controlOptionP: .init(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))
            case .controlShiftSpace: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
            }
        }
    }

    private static let listCopyStyleKey = "panelListCopyStyle"
    private static let toggleHotKeyKey = "panelToggleHotKey"

    static var listCopyStyle: ItemFormatter.ListStyle {
        get {
            UserDefaults.standard.string(forKey: listCopyStyleKey)
                .flatMap(ItemFormatter.ListStyle.init(rawValue:)) ?? .numbered
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: listCopyStyleKey)
        }
    }

    static var toggleHotKey: ToggleHotKey {
        get {
            UserDefaults.standard.string(forKey: toggleHotKeyKey)
                .flatMap(ToggleHotKey.init(rawValue:)) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: toggleHotKeyKey)
        }
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
