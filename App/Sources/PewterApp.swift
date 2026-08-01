import SwiftUI

@main
struct PewterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement app: no real windows here. This empty scene is the
        // mandatory placeholder — real settings are SettingsWindowController,
        // since SwiftUI's Settings scene needs activation-policy hacks for
        // accessory apps and is broken on macOS 26.
        Settings {
            EmptyView()
        }
        // The scene installs an app-menu "Settings…" bound to ⌘, that would
        // open the empty scene from our own key windows; rebind it to the
        // real window.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
