import AppKit
import os
import SwiftUI

@MainActor
final class PanelController {
    private static let logger = Logger(subsystem: "com.oakoss.SmartList", category: "panel")

    private let panel: FloatingPanel

    init(rootView: some View) {
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
        panel.setFrameAutosaveName("SmartListPanel")
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle(relativeTo statusButton: NSStatusBarButton?) {
        if panel.isVisible {
            hide()
        } else {
            show(relativeTo: statusButton)
        }
    }

    func show(relativeTo statusButton: NSStatusBarButton? = nil) {
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
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame SmartListPanel") != nil
        if !hasSavedFrame, let button = statusButton, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.frame
            let origin = NSPoint(
                x: buttonFrame.midX - panel.frame.width / 2,
                y: buttonFrame.minY - panel.frame.height - 4
            )
            panel.setFrameOrigin(constrained(origin, for: buttonWindow.screen))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func constrained(_ origin: NSPoint, for screen: NSScreen?) -> NSPoint {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return origin }
        var origin = origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        return origin
    }
}
