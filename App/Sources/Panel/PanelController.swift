import AppKit
import os
import PewterCore
import SwiftUI

@MainActor
final class PanelController {
    private static let logger = Logger.panel

    private let panel: FloatingPanel
    /// Runs before the panel appears. Non-optional so a wiring gap is a
    /// compile error rather than a panel that silently stops recovering.
    private let onWillShow: () -> Void

    init(rootView: some View, onWillShow: @escaping () -> Void) {
        self.onWillShow = onWillShow
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480))
        // The hidden titlebar reserves a top safe-area inset (dead space
        // above the search field); ignore it inside SwiftUI. Clearing
        // NSHostingView.safeAreaRegions instead triggers an AppKit
        // constraint feedback loop that grows the window unboundedly.
        let hosting = NSHostingView(rootView: rootView.ignoresSafeArea(.container, edges: .top))
        hosting.sizingOptions = []
        panel.contentView = hosting
        // sizingOptions = [] also drops the SwiftUI minSize propagation;
        // without an explicit floor the panel can be dragged unusably small.
        panel.contentMinSize = NSSize(width: 320, height: 360)
        panel.setFrameAutosaveName("PewterPanel")
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle(relativeTo statusButton: NSStatusBarButton?, onActiveScreen: Bool = false) {
        if panel.isVisible {
            hide()
        } else {
            show(relativeTo: statusButton, onActiveScreen: onActiveScreen)
        }
    }

    func show(relativeTo statusButton: NSStatusBarButton? = nil, onActiveScreen: Bool = false) {
        // Summoning the panel is the user checking whether things work yet,
        // which makes it the natural moment to re-read a file that couldn't
        // be read at launch.
        onWillShow()
        // A corrupted autosaved frame (e.g. from a layout loop) must never
        // brick the panel; clamp anything implausible back to the default.
        if let screen = panel.screen ?? NSScreen.main,
           panel.frame.height > screen.frame.height || panel.frame.width > screen.frame.width
           || panel.frame.height < 360 || panel.frame.width < 320
        {
            let width = panel.frame.width
            let height = panel.frame.height
            Self.logger.notice("autosaved panel frame implausible (\(width)x\(height)); resetting")
            panel.setContentSize(NSSize(width: 360, height: 480))
        }

        // Anchor under the status item only when there's no saved frame —
        // once the user drags the panel, their position wins.
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame PewterPanel") != nil
        if !hasSavedFrame, let button = statusButton, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.frame
            let origin = NSPoint(
                x: buttonFrame.midX - panel.frame.width / 2,
                y: buttonFrame.minY - panel.frame.height - 4
            )
            panel.setFrameOrigin(constrained(origin, for: buttonWindow.screen))
        }
        // Hotkey summons follow the user (Spotlight model): a saved frame
        // sitting on another display is translated onto the active screen,
        // keeping its offset. Status-item clicks keep the saved position —
        // the click already happened on whichever screen the user chose.
        if onActiveScreen, hasSavedFrame,
           let target = Self.activeScreen(),
           !target.frame.intersects(panel.frame)
        {
            let screens = NSScreen.screens
            let source = ScreenGeometry.screenIndex(for: panel.frame, in: screens.map(\.frame))
                .map { screens[$0].visibleFrame }
            let moved = PanelPlacement.translate(
                frame: panel.frame,
                // A frame on no screen at all (display unplugged mid-run)
                // has no offset worth preserving; identity-translate so it
                // clamps back onto the target screen.
                from: source ?? target.visibleFrame,
                to: target.visibleFrame
            )
            panel.setFrame(moved, display: false)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The screen the user is working on. Mouse position is the only
    /// permission-free signal: NSScreen.main is per-app and reports the
    /// menu-bar screen while our panel is hidden, and reading the frontmost
    /// app's key window would need the Accessibility grant this hotkey
    /// deliberately works without. NSMouseInRect, not CGRect.contains — a
    /// cursor parked on the top pixel row sits exactly at maxY, which
    /// contains() excludes. nil (mouse on no screen) means the caller keeps
    /// the saved position rather than guessing.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// Deliberately partial, unlike ScreenGeometry.clamp: this only runs
    /// for status-item-anchored placement, where the anchor already fixes
    /// the top edge — pinning it too would shift the panel off its 4pt
    /// gap under the menu bar. The x-ordering also differs (right edge
    /// wins for an over-wide panel), so neither axis migrates cleanly.
    private func constrained(_ origin: NSPoint, for screen: NSScreen?) -> NSPoint {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return origin }
        var origin = origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        return origin
    }
}
