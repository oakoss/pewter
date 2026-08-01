import AppKit
import Carbon.HIToolbox
import os
import PewterCore

/// Fallback capture for apps that don't expose their selection to the
/// Accessibility API: synthesize Cmd+C, read the pasteboard, put the user's
/// previous clipboard back. This is only the AppKit adapter — the
/// sequencing and every fallback decision live in Core's
/// `PasteboardCaptureRunner`.
@MainActor
struct PasteboardCapture: PasteboardCapturing, PasteboardCaptureSurface {
    private static let logger = Logger(subsystem: "com.oakoss.Pewter", category: "capture")

    /// True when the clipboard changed within the last few seconds. TUIs
    /// (Claude Code) auto-copy their selection on select, so recent activity
    /// plus a dead synthetic Cmd+C means the clipboard already holds the
    /// selection. Required at init — a defaulted `false` would silently
    /// disable the TUI capture path if the wiring were ever dropped.
    private let recentChange: @MainActor () -> Bool

    /// Bracket this capture's clipboard traffic (synthesis through restore)
    /// so it never reads as selection activity.
    private let ownWritesBegin: @MainActor () -> Void
    private let ownWritesEnd: @MainActor () -> Void

    init(
        recentClipboardChange: @escaping @MainActor () -> Bool,
        beginOwnWrites: @escaping @MainActor () -> Void,
        endOwnWrites: @escaping @MainActor () -> Void
    ) {
        recentChange = recentClipboardChange
        ownWritesBegin = beginOwnWrites
        ownWritesEnd = endOwnWrites
    }

    func capture() async -> PasteboardCaptureResult {
        // Wait for physical modifiers to clear before synthesizing: the chord
        // hotkey fires on key-down with its modifiers guaranteed held, and on
        // the tap path the key-up event can precede the combined-state flags
        // clearing. A lingering hardware modifier turns our Cmd+C into a
        // different chord in some target apps. Cmd is excluded from the wait
        // set — it's the chord being synthesized.
        for _ in 0 ..< 20 {
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskShift, .maskControl, .maskAlternate])
            if held.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(15))
            guard !Task.isCancelled else { return .failed }
        }
        if !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty
        {
            Self.logger.warning("modifiers still held after 300 ms wait; synthesizing Cmd+C anyway")
        }
        try? await Task.sleep(for: .milliseconds(15))
        guard !Task.isCancelled else { return .failed }

        return await PasteboardCaptureRunner.run(on: self)
    }

    // MARK: - PasteboardCaptureSurface

    var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    var frontmostAppPid: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Best flavor first: HTML, then RTF, converted to Markdown so captured
    /// formatting survives in a file that already speaks Markdown. An
    /// unstyled conversion steps aside for the plain flavor, which keeps
    /// the source's exact whitespace that the HTML walk collapses; every
    /// abandoned flavor logs why, so a "formatting disappeared" report has
    /// a trail.
    func capturedText() -> String? {
        let pasteboard = NSPasteboard.general
        var unstyled: String?

        if let data = pasteboard.data(forType: .html) {
            if let html = HTMLMarkdown.decode(data) {
                if let conversion = HTMLMarkdown.convert(fromHTML: html) {
                    if conversion.styled {
                        return conversion.markdown
                    }
                    unstyled = conversion.markdown
                } else {
                    Self.logger.debug("html flavor (\(data.count) bytes) yielded no markdown; trying rtf")
                }
            } else {
                Self.logger.info("html flavor (\(data.count) bytes) decoded as neither utf8 nor utf16; trying rtf")
            }
        }

        if let data = pasteboard.data(forType: .rtf) {
            // Same ceiling as HTML: the RTF importer is even costlier per
            // byte, and it runs on the main actor mid-gesture.
            if data.count > HTMLMarkdown.byteCeiling {
                Self.logger.debug("rtf flavor (\(data.count) bytes) over the conversion ceiling; trying plain string")
            } else if let blocks = AttributedTextBlocks.blocks(fromRTF: data),
                      blocks.requiresMarkdown
            {
                let markdown = MarkdownWriter.markdown(from: blocks)
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return markdown
                }
                Self.logger.debug("rtf flavor converted to empty markdown; trying plain string")
            }
        }

        // The unstyled conversion is only a rescue for rich-only
        // pasteboards; a present plain flavor always wins on fidelity.
        return pasteboard.string(forType: .string) ?? unstyled
    }

    func recentClipboardChange() -> Bool {
        recentChange()
    }

    func beginOwnWrites() {
        ownWritesBegin()
    }

    func endOwnWrites() {
        ownWritesEnd()
    }

    /// Types worth restoring. Materializing every flavor would force
    /// provider IPC for large promised payloads (Photoshop, Keynote) and
    /// stall the main thread mid-gesture.
    private static let restorableTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html, .URL, .fileURL, .tiff, .png, .pdf,
    ]

    func saveClipboard() -> [NSPasteboardItem]? {
        let saved = (NSPasteboard.general.pasteboardItems ?? []).compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var copiedAnything = false
            for type in item.types where Self.restorableTypes.contains(type) {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    copiedAnything = true
                }
            }
            if !copiedAnything, !item.types.isEmpty {
                Self.logger.debug("clipboard item held no restorable types; restore will be partial")
            }
            return copiedAnything ? copy : nil
        }
        return saved.isEmpty ? nil : saved
    }

    func restoreClipboard(_ snapshot: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects(snapshot) {
            Self.logger.error("failed to restore previous clipboard contents")
        }
    }

    func synthesizeCopy(to pid: pid_t?) async -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let key = CGKeyCode(kVK_ANSI_C)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        // Explicit flags on the synthetic event; target apps can still merge
        // hardware modifier state, hence the wait above.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if let pid {
            keyDown.postToPid(pid)
        } else {
            keyDown.post(tap: .cghidEventTap)
        }
        // A human-scale gap between down and up: apps that run their own
        // event processing (GPU terminals) can drop a zero-duration press.
        try? await Task.sleep(for: .milliseconds(25))
        if let pid {
            keyUp.postToPid(pid)
        } else {
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Waits up to ~300 ms for the target app to service the copy.
    func pollForChange(from baseline: Int) async -> Int? {
        let pasteboard = NSPasteboard.general
        for _ in 0 ..< 15 {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled {
                return nil
            }
            if pasteboard.changeCount != baseline {
                return pasteboard.changeCount
            }
        }
        return nil
    }
}
