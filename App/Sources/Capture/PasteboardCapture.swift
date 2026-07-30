import AppKit
import Carbon.HIToolbox
import os
import PewterCore

/// Fallback capture for apps that don't expose their selection to the
/// Accessibility API: synthesize Cmd+C, read the pasteboard, put the user's
/// previous clipboard back.
struct PasteboardCapture: PasteboardCapturing {
    private static let logger = Logger(subsystem: "com.oakoss.Pewter", category: "capture")

    /// True when the clipboard changed within the last few seconds. TUIs
    /// (Claude Code) auto-copy their selection on select, so recent activity
    /// plus a dead synthetic Cmd+C means the clipboard already holds the
    /// selection. Required at init — a defaulted `false` would silently
    /// disable the TUI capture path if the wiring were ever dropped.
    let recentClipboardChange: @MainActor () -> Bool

    /// Bracket this capture's clipboard traffic (synthesis through restore)
    /// so it never reads as selection activity.
    let beginOwnWrites: @MainActor () -> Void
    let endOwnWrites: @MainActor () -> Void

    @MainActor
    func capture() async -> PasteboardCaptureResult {
        let pasteboard = NSPasteboard.general

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

        // Snapshot immediately before the copy — taken any earlier, a
        // clipboard-manager write during the modifier wait would read as our
        // copy landing, capturing foreign content and clobbering it on
        // restore.
        let saved = snapshot(pasteboard)
        let baseline = pasteboard.changeCount

        beginOwnWrites()
        defer { endOwnWrites() }

        guard await postCommandC(to: nil) else {
            Self.logger.error("Cmd+C synthesis failed; capture aborted")
            return .failed
        }

        var changeCountAfterCopy = await pollForChange(on: pasteboard, baseline: baseline)
        guard !Task.isCancelled else { return .failed }

        // Some GPU terminals ignore synthetic events from the HID tap but
        // accept them delivered directly to their process.
        if changeCountAfterCopy == nil {
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                Self.logger.info("HID-tap copy ignored; retrying via postToPid")
                guard await postCommandC(to: pid) else { return .failed }
                changeCountAfterCopy = await pollForChange(on: pasteboard, baseline: baseline)
                guard !Task.isCancelled else { return .failed }
            } else {
                Self.logger.info("HID-tap copy ignored and no frontmost app; skipping postToPid retry")
            }
        }

        guard let changeCountAfterCopy else {
            // A copy landing after the poll windows is still OUR copy —
            // route it through the normal restore path, or the user's
            // clipboard is lost and the tracker mistakes it for activity.
            // Snapshot the count once: reading it live at the restore call
            // would be tautological and disable the anti-clobber guard.
            let lateCount = pasteboard.changeCount
            if lateCount != baseline {
                Self.logger.info("copy landed after poll window; treating as ours")
                let late = pasteboard.string(forType: .string)
                restore(saved, to: pasteboard, expectedChangeCount: lateCount)
                guard let late, !late.isEmpty else { return .nothingSelected }
                return .copied(late)
            }
            // No copy at all. If the clipboard changed moments before the
            // capture, a TUI's copy-on-select already delivered the
            // selection there — use it (and leave it; it belongs to this
            // selection).
            if recentClipboardChange() {
                if let recent = pasteboard.string(forType: .string), !recent.isEmpty {
                    Self.logger.info("using recently auto-copied clipboard content")
                    return .copied(recent)
                }
                Self.logger.info("recent clipboard change held no string content")
                return .nothingSelected
            }
            // Otherwise: nothing was selected; the clipboard is untouched.
            Self.logger.debug("no pasteboard change within capture window")
            return .nothingSelected
        }

        let copied = pasteboard.string(forType: .string)

        // Restore even when the copy produced no text (image/file selection) —
        // the synthetic copy still replaced the user's clipboard.
        restore(saved, to: pasteboard, expectedChangeCount: changeCountAfterCopy)

        guard let copied, !copied.isEmpty else { return .nothingSelected }
        return .copied(copied)
    }

    // MARK: - Clipboard snapshot / restore

    /// Types worth restoring. Materializing every flavor would force
    /// provider IPC for large promised payloads (Photoshop, Keynote) and
    /// stall the main thread mid-gesture.
    private static let restorableTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html, .URL, .fileURL, .tiff, .png, .pdf,
    ]

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
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
    }

    private func restore(
        _ items: [NSPasteboardItem],
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
        // An empty snapshot (nothing restorable was on the clipboard) must
        // not clear: leaving the captured text beats erasing everything.
        guard !items.isEmpty else {
            Self.logger.debug("no restorable snapshot; leaving captured content on clipboard")
            return
        }
        // If something else wrote to the clipboard since our synthetic copy
        // (clipboard manager, the user), don't clobber it.
        guard pasteboard.changeCount == expectedChangeCount else {
            Self.logger.debug("clipboard changed since capture; skipping restore")
            return
        }
        pasteboard.clearContents()
        if !pasteboard.writeObjects(items) {
            Self.logger.error("failed to restore previous clipboard contents")
        }
    }

    // MARK: - Synthetic Cmd+C

    /// Waits up to ~300 ms for the target app to service the copy; returns
    /// the post-copy change count, or nil if the pasteboard never changed.
    @MainActor
    private func pollForChange(on pasteboard: NSPasteboard, baseline: Int) async -> Int? {
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

    /// Posts Cmd+C to the HID tap (pid nil), or directly to a process.
    private func postCommandC(to pid: pid_t?) async -> Bool {
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
}
