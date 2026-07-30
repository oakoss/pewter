import AppKit

/// Tracks when the system clipboard last changed — change counts only, never
/// content. TUIs like Claude Code auto-copy their in-app selection to the
/// clipboard (OSC 52) the moment text is selected; a capture that finds no
/// terminal selection and no response to synthetic Cmd+C can still succeed by
/// using clipboard content that arrived moments ago.
@MainActor
final class ClipboardActivityTracker {
    private var lastChangeCount: Int
    private var lastChangeAt: Date?
    private var timer: Timer?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        // Weak capture on the Timer closure itself — on the inner Task it
        // leaves the timer retaining self and the deinit unreachable.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        // .common, not .default: menu tracking and window drags suspend
        // default-mode timers, and a change first observed after a long
        // stall would be stamped as fresh activity.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    isolated deinit {
        timer?.invalidate()
    }

    func changedRecently(within interval: TimeInterval) -> Bool {
        poll()
        guard let lastChangeAt else { return false }
        return Date().timeIntervalSince(lastChangeAt) <= interval
    }

    /// Bracket the app's own clipboard writes (item copy, capture synthesis
    /// and restore) so they never read as selection activity. Bracketing —
    /// rather than acknowledging after the fact — closes the race where the
    /// 1 s poller fires mid-capture and stamps our own write as activity.
    func beginOwnWrites() {
        poll()
        ownWriteDepth += 1
    }

    func endOwnWrites() {
        lastChangeCount = NSPasteboard.general.changeCount
        ownWriteDepth = max(0, ownWriteDepth - 1)
    }

    private var ownWriteDepth = 0

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ownWriteDepth == 0 {
            lastChangeAt = Date()
        }
    }
}
