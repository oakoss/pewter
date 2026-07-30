import SwiftUI

@main
struct PewterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement app: no windows here; everything hangs off the status item.
        Settings {
            EmptyView()
        }
    }
}
