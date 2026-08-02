import Foundation
import os

/// The OS surface the capture runner drives. The App implements it over
/// NSPasteboard/CGEvent; tests fake it so the retry and restore sequencing
/// runs under `swift test`.
@MainActor
public protocol PasteboardCaptureSurface {
    /// Opaque saved-clipboard token: restoring is only possible with the
    /// token `saveClipboard` produced, so restore-without-save and
    /// stale-snapshot reuse are unrepresentable.
    associatedtype Snapshot

    var changeCount: Int { get }
    var frontmostAppPid: pid_t? { get }
    /// The clipboard's capturable flavors, read raw — `RichCapture` owns
    /// which one becomes the note.
    func pasteboardFlavors() -> PasteboardFlavors
    /// Decodes an RTF flavor into blocks (AppKit's importer in the app);
    /// nil when the data doesn't import.
    func rtfBlocks(_ data: Data) -> [RichTextBlock]?
    /// Saves restorable clipboard contents; nil when nothing restorable
    /// was present.
    func saveClipboard() -> Snapshot?
    /// Writes the saved contents back unconditionally — the runner owns
    /// the decision of whether that is safe.
    func restoreClipboard(_ snapshot: Snapshot)
    /// Synthesizes Cmd+C to the HID tap (nil) or a specific process.
    func synthesizeCopy(to pid: pid_t?) async -> Bool
    /// Waits for `changeCount` to leave `baseline`. A non-nil return is
    /// the pasteboard's live change count at that moment — the restore
    /// guard compares against it.
    func pollForChange(from baseline: Int) async -> Int?
    /// Whether the clipboard changed shortly before this capture
    /// (copy-on-select apps deliver the selection the moment it is made).
    /// Polls — and thereby mutates — tracker state.
    func recentClipboardChange() -> Bool
    func beginOwnWrites()
    func endOwnWrites()
}

/// Sequencing for the pasteboard tier: synthesize → poll → pid retry →
/// late-copy attribution → capture/restore. Lives in Core over an injected
/// surface so the branches that need a GPU terminal or a clipboard manager
/// to reproduce live are table-testable.
public enum PasteboardCaptureRunner {
    private static let logger = Logger.capture

    @MainActor
    public static func run(on surface: some PasteboardCaptureSurface) async -> PasteboardCaptureResult {
        // Snapshot immediately before the copy — taken any earlier, a
        // foreign write during the caller's pre-copy waits would read as
        // our copy landing, capturing foreign content and clobbering it on
        // restore.
        let snapshot = surface.saveClipboard()
        let baseline = surface.changeCount

        surface.beginOwnWrites()
        defer { surface.endOwnWrites() }

        guard await surface.synthesizeCopy(to: nil) else {
            logger.error("Cmd+C synthesis failed; capture aborted")
            return .failed
        }

        var landedCount = await surface.pollForChange(from: baseline)
        guard !Task.isCancelled else { return .failed }

        // Some GPU terminals ignore synthetic events from the HID tap but
        // accept them delivered directly to their process.
        if landedCount == nil {
            if let pid = surface.frontmostAppPid {
                logger.info("HID-tap copy ignored; retrying via postToPid")
                guard await surface.synthesizeCopy(to: pid) else {
                    logger.error("postToPid Cmd+C synthesis failed; capture aborted")
                    return .failed
                }
                landedCount = await surface.pollForChange(from: baseline)
                guard !Task.isCancelled else { return .failed }
            } else {
                logger.info("HID-tap copy ignored and no frontmost app; skipping postToPid retry")
            }
        }

        // A copy landing after the poll windows is still OUR copy — treat
        // it as landed so the user's clipboard is put back. Read the count
        // once: re-reading it at the restore check would be tautological
        // and disable the anti-clobber guard.
        if landedCount == nil {
            let lateCount = surface.changeCount
            if lateCount != baseline {
                logger.info("copy landed after poll window; treating as ours")
                landedCount = lateCount
            }
        }

        if let landedCount {
            let result = PasteboardCapturePolicy.capturedResult(from: capturedText(on: surface))
            restoreIfSafe(on: surface, snapshot: snapshot, expectedChangeCount: landedCount)
            return result
        }

        // Only consulted when no copy landed: `recentClipboardChange`
        // mutates tracker state, and touching it on the landed path would
        // lean on the own-writes bracketing staying exactly as wide as it
        // is today. Recent activity plus a dead copy means the clipboard
        // already holds this selection — use it and leave it there.
        if surface.recentClipboardChange() {
            let result = PasteboardCapturePolicy.capturedResult(from: capturedText(on: surface))
            if case .copied = result {
                logger.info("using recently auto-copied clipboard content")
            } else {
                logger.info("recent clipboard change held no string content")
            }
            return result
        }

        logger.debug("no pasteboard change within capture window")
        return .nothingSelected
    }

    @MainActor
    private static func capturedText(on surface: some PasteboardCaptureSurface) -> String? {
        RichCapture.text(from: surface.pasteboardFlavors(), rtfBlocks: { surface.rtfBlocks($0) })
    }

    @MainActor
    private static func restoreIfSafe<Surface: PasteboardCaptureSurface>(
        on surface: Surface,
        snapshot: Surface.Snapshot?,
        expectedChangeCount: Int
    ) {
        switch PasteboardCapturePolicy.restoreDecision(
            snapshotIsEmpty: snapshot == nil,
            changeCount: surface.changeCount,
            expectedChangeCount: expectedChangeCount
        ) {
        case .skipEmptySnapshot:
            logger.debug("no restorable snapshot; leaving captured content on clipboard")
        case .skipClipboardMoved:
            logger.debug("clipboard changed since capture; skipping restore")
        case .restore:
            // The decision implies the snapshot exists; the unwrap is for
            // the compiler.
            if let snapshot {
                surface.restoreClipboard(snapshot)
            }
        }
    }
}
