/// A launcher command shared by the status item's right-click menu and the
/// panel's ellipsis menu. The table here is the single source of menu
/// contents; the App layer attaches an action per `ID`.
public struct MenuCommand: Equatable, Sendable, Identifiable {
    public enum ID: CaseIterable, Hashable, Sendable {
        case revealNotesFile
        case settings
        case permissions
        case copyDiagnostics
        case quit
    }

    public let id: ID
    public let title: String
    /// Consumed by the AppKit status-item menu while it is open; the SwiftUI
    /// renderer ignores it. Empty for commands without one.
    public let keyEquivalent: String
}

public enum AppMenu {
    /// Grouped commands; renderers place a separator between groups.
    public static let groups: [[MenuCommand]] = [
        [
            MenuCommand(id: .revealNotesFile, title: "Reveal Notes File in Finder", keyEquivalent: ""),
        ],
        [
            // Configuration lives in the settings window; the menu stays a
            // launcher. Cmd+, is what menubar-app users reflexively try.
            MenuCommand(id: .settings, title: "Settings…", keyEquivalent: ","),
            MenuCommand(id: .permissions, title: "Permissions…", keyEquivalent: ""),
            MenuCommand(id: .copyDiagnostics, title: "Copy Diagnostics", keyEquivalent: ""),
        ],
        [
            MenuCommand(id: .quit, title: "Quit Pewter", keyEquivalent: "q"),
        ],
    ]
}
