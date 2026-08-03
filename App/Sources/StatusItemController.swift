import Accessibility
import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onToggle: (NSStatusBarButton?) -> Void
    private let onRevealFile: () -> Void
    private let onShowSettings: () -> Void
    private let onShowPermissions: () -> Void
    private let onCopyDiagnostics: () -> Void

    init(
        onToggle: @escaping (NSStatusBarButton?) -> Void,
        onRevealFile: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onShowPermissions: @escaping () -> Void,
        onCopyDiagnostics: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onToggle = onToggle
        self.onRevealFile = onRevealFile
        self.onShowSettings = onShowSettings
        self.onShowPermissions = onShowPermissions
        self.onCopyDiagnostics = onCopyDiagnostics
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "checklist",
                accessibilityDescription: "Pewter"
            )
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    var button: NSStatusBarButton? {
        statusItem.button
    }

    private var flashTask: Task<Void, Never>?

    /// Names the flash image so VoiceOver reads the state instead of an
    /// unlabeled button when the user navigates to the status item — and
    /// announces it, because a brief symbol swap in the menu bar is
    /// invisible to a VoiceOver user who never navigates there. macOS only
    /// speaks announcements from the frontmost app, so on the capture path
    /// (source app frontmost) delivery is best-effort — the manual VO
    /// checklist gates on what a live session actually speaks.
    func flash(symbolName: String, description: String, duration: TimeInterval = 0.8) {
        guard let button = statusItem.button else { return }
        AccessibilityNotification.Announcement(description).post()
        // Cancel the previous restore or two quick flashes would clear the
        // second one's symbol early.
        flashTask?.cancel()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        flashTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Pewter")
        }
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        // Control-click is the trackpad secondary click; treat it as
        // right-click or the menu is unreachable without a mouse.
        let isSecondaryClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondaryClick {
            showMenu()
        } else {
            onToggle(statusItem.button)
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let reveal = NSMenuItem(title: "Reveal Notes File in Finder", action: #selector(revealFile), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        // Configuration lives in the settings window; the menu stays a
        // launcher. Cmd+, is what menubar-app users reflexively try.
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let permissions = NSMenuItem(title: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let diagnostics = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Pewter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        // Pop directly instead of the assign-menu-and-performClick dance:
        // synthesizing a click lets menubar managers (Bartender) intercept
        // it and flash their own menu first. The clearance matters: macOS 26
        // reserves a band under the menu bar, and a menu anchored inside it
        // opens in a scrolled state — a chevron replaces the first item.
        // With a nil view the point is in screen coordinates and popUp
        // anchors the menu's top-left corner — top-right under RTL, picked
        // from NSApp.userInterfaceLayoutDirection.
        guard let button = statusItem.button, let window = button.window else {
            assertionFailure("status item button has no window")
            return
        }
        let menuBarClearance: CGFloat = 8
        let x = NSApp.userInterfaceLayoutDirection == .rightToLeft
            ? window.frame.maxX
            : window.frame.minX
        // popUp tracks modally, so the highlight brackets the menu's lifetime.
        button.highlight(true)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: x, y: window.frame.minY - menuBarClearance),
            in: nil
        )
        button.highlight(false)
    }

    @objc private func revealFile() {
        onRevealFile()
    }

    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func showPermissions() {
        onShowPermissions()
    }

    @objc private func copyDiagnostics() {
        onCopyDiagnostics()
    }
}
