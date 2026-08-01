import AppKit

/// Non-activating floating panel: takes keyboard input without activating the
/// app, so the frontmost app keeps focus while the user works the list.
final class FloatingPanel: NSPanel, NSWindowDelegate {
    /// Own constant, not `minSize`: the hosting machinery resets the
    /// window's min size to zero at runtime, so anything derived from the
    /// property silently stops clamping.
    static let minimumSize = NSSize(width: 320, height: 360)
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        delegate = self

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
        contentMinSize = Self.minimumSize
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

    /// `contentMinSize` alone is not enforced during this panel's live
    /// resize; the delegate callback is, so the floor lives here.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, Self.minimumSize.width),
            height: max(frameSize.height, Self.minimumSize.height)
        )
    }

    /// Accessibility-driven resizes (window managers, tiling tools) bypass
    /// the delegate; correcting after the fact is the only floor that holds
    /// for every path. Re-entry terminates because the corrected frame
    /// passes the guard.
    func windowDidResize(_ notification: Notification) {
        let size = frame.size
        guard size.width < Self.minimumSize.width || size.height < Self.minimumSize.height else { return }
        var corrected = frame
        corrected.size.width = max(size.width, Self.minimumSize.width)
        corrected.size.height = max(size.height, Self.minimumSize.height)
        setFrame(corrected, display: true)
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
