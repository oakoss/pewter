import AppKit

@MainActor
enum Pasteboard {
    /// Wired to ClipboardActivityTracker's own-write bracketing so the app's
    /// copies never register as selection activity for the capture fallback.
    static var beginOwnWrite: (() -> Void)?
    static var endOwnWrite: (() -> Void)?

    static func write(_ text: String) {
        beginOwnWrite?()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        endOwnWrite?()
    }
}
