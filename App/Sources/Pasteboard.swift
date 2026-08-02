import AppKit
import os
import PewterCore

@MainActor
enum Pasteboard {
    /// Wired to ClipboardActivityTracker's own-write bracketing so the app's
    /// copies never register as selection activity for the capture fallback.
    static var beginOwnWrite: (() -> Void)?
    static var endOwnWrite: (() -> Void)?

    /// False when the write failed — and `clearContents` has already run,
    /// so the clipboard is empty, not stale. Callers claiming "copied" in
    /// their feedback must check.
    @discardableResult
    static func write(_ text: String) -> Bool {
        beginOwnWrite?()
        defer { endOwnWrite?() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        if !wrote {
            Logger.panel.error("pasteboard write failed")
        }
        return wrote
    }
}
