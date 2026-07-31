import AppKit

/// Non-activating floating panel: takes keyboard input without activating the
/// app, so the frontmost app keeps focus while the user works the list.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Visually hidden, but VoiceOver announces the window by it.
        title = "Pewter"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // AppKit's default. With `true`, AppKit swallows the click that
        // re-keys an unkeyed panel, so a row click would not also select.
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        animationBehavior = .utilityWindow
    }

    /// Required for text fields to accept input; the app still never activates.
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        // Declarative key acquisition is unreliable for a non-activating
        // panel once another app holds key — shortcuts then leak into that
        // app. Reclaim key on any click, the same call the status-item
        // toggle uses; the app still never activates.
        if !isKeyWindow, event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}
