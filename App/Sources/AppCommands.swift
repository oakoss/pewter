import PewterCore

/// The actions behind `AppMenu`'s command table. One stored closure per
/// `MenuCommand.ID` keeps the mapping exhaustive: a new ID doesn't compile
/// until its action exists.
@MainActor
struct AppCommands {
    let revealNotesFile: () -> Void
    let settings: () -> Void
    /// Unconditional, unlike the permission banner's showIfNeeded — a menu
    /// item must open the window even when access is already granted.
    let permissions: () -> Void
    let copyDiagnostics: () -> Void
    let quit: () -> Void

    func run(_ id: MenuCommand.ID) {
        switch id {
        case .revealNotesFile: revealNotesFile()
        case .settings: settings()
        case .permissions: permissions()
        case .copyDiagnostics: copyDiagnostics()
        case .quit: quit()
        }
    }
}
