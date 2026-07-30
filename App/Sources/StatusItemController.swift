import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onToggle: (NSStatusBarButton?) -> Void
    private let onRevealFile: () -> Void
    private let onShowPermissions: () -> Void
    private let onSelectTapModifier: (CaptureSettings.TapModifier) -> Void
    private let onSelectChordHotKey: (CaptureSettings.ChordHotKey) -> Void

    init(
        onToggle: @escaping (NSStatusBarButton?) -> Void,
        onRevealFile: @escaping () -> Void,
        onShowPermissions: @escaping () -> Void,
        onSelectTapModifier: @escaping (CaptureSettings.TapModifier) -> Void,
        onSelectChordHotKey: @escaping (CaptureSettings.ChordHotKey) -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onToggle = onToggle
        self.onRevealFile = onRevealFile
        self.onShowPermissions = onShowPermissions
        self.onSelectTapModifier = onSelectTapModifier
        self.onSelectChordHotKey = onSelectChordHotKey
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "checklist",
                accessibilityDescription: "smart-list"
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

    func flash(symbolName: String, duration: TimeInterval = 0.8) {
        guard let button = statusItem.button else { return }
        // Cancel the previous restore or two quick flashes would clear the
        // second one's symbol early.
        flashTask?.cancel()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        flashTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "smart-list")
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

        let shortcutMenu = NSMenu()
        for modifier in CaptureSettings.TapModifier.allCases {
            let item = NSMenuItem(
                title: modifier.menuTitle,
                action: #selector(selectTapModifier(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = modifier.rawValue
            item.state = modifier == CaptureSettings.tapModifier ? .on : .off
            shortcutMenu.addItem(item)
        }
        let shortcutItem = NSMenuItem(title: "Capture Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        let chordMenu = NSMenu()
        for chord in CaptureSettings.ChordHotKey.allCases {
            let item = NSMenuItem(title: chord.menuTitle, action: #selector(selectChordHotKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = chord.rawValue
            item.state = chord == CaptureSettings.chordHotKey ? .on : .off
            chordMenu.addItem(item)
        }
        let chordItem = NSMenuItem(title: "Capture Hotkey", action: nil, keyEquivalent: "")
        chordItem.submenu = chordMenu
        menu.addItem(chordItem)

        let permissions = NSMenuItem(title: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit smart-list",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        // Pop directly instead of the assign-menu-and-performClick dance:
        // synthesizing a click lets menubar managers (Bartender) intercept
        // it and flash their own menu first.
        if let button = statusItem.button {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.maxY + 4),
                in: button
            )
        }
    }

    @objc private func revealFile() {
        onRevealFile()
    }

    @objc private func showPermissions() {
        onShowPermissions()
    }

    @objc private func selectTapModifier(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let modifier = CaptureSettings.TapModifier(rawValue: raw)
        else {
            assertionFailure("menu item carried an unknown tap modifier")
            return
        }
        onSelectTapModifier(modifier)
    }

    @objc private func selectChordHotKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chord = CaptureSettings.ChordHotKey(rawValue: raw)
        else {
            assertionFailure("menu item carried an unknown chord hotkey")
            return
        }
        onSelectChordHotKey(chord)
    }
}
