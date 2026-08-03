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
    /// Stable identity for trust decisions — copy-on-select is an app
    /// property, not a process property.
    var frontmostAppBundleID: String? { get }
    /// Blocks until synthesizing Cmd+C is safe (lingering hardware
    /// modifiers would turn it into a different chord). Called by the
    /// runner immediately before synthesis so paths that never synthesize
    /// never pay the wait.
    func awaitSynthesisReady() async
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

/// Session-scoped trust ledger for apps whose synthetic copies die and
/// whose captures succeed via the recent-clipboard assist. For a trusted
/// source the assist answer IS what the full sequence would return — the
/// app can't answer a re-sent Cmd+C — so later captures may take it up
/// front instead of burning both poll windows to rediscover the same dead
/// end. Keyed by bundle identifier: copy-on-select is an application
/// property, so trust survives an app relaunch and no process-lifetime
/// bookkeeping is needed.
///
/// Trust is earned twice and stays falsifiable. Twice, because the tracker
/// can't attribute a clipboard write to a process — one assist success can
/// be a coincidental foreign write, and one coincidence must not classify
/// an app. Falsifiable, because the fast path never synthesizes: without
/// periodic re-proof, an app whose behavior changed (copy-on-select turned
/// off) could keep its stale trust forever.
@MainActor
public final class CopyOnSelectSources {
    private static let trustThreshold = 2
    /// Every Nth eligible capture declines the fast path so the full
    /// sequence re-proves the classification — either the assist
    /// re-teaches it or a landed synthesis contradicts it.
    private static let reproofInterval = 8

    private var sightings: [String: Int] = [:]
    private var trustedUses: [String: Int] = [:]

    public init() {}

    public func recordAssistSuccess(_ key: String?) {
        guard let key else { return }
        sightings[key, default: 0] += 1
    }

    /// A landed synthesis disproves copy-on-select; trust restarts from
    /// zero.
    public func recordContradiction(_ key: String?) {
        guard let key else { return }
        sightings[key] = nil
        trustedUses[key] = nil
    }

    /// Also counts eligible captures, to pace the re-proof turns.
    public func shouldFastPath(_ key: String?) -> Bool {
        guard let key, sightings[key, default: 0] >= Self.trustThreshold else { return false }
        let uses = trustedUses[key, default: 0] + 1
        trustedUses[key] = uses
        return uses % Self.reproofInterval != 0
    }
}

/// Sequencing for the pasteboard tier: synthesize → poll → pid retry →
/// late-copy attribution → capture/restore. Lives in Core over an injected
/// surface so the branches that need a GPU terminal or a clipboard manager
/// to reproduce live are table-testable.
public enum PasteboardCaptureRunner {
    private static let logger = Logger.capture

    @MainActor
    public static func run(
        on surface: some PasteboardCaptureSurface,
        sources: CopyOnSelectSources
    ) async -> PasteboardCaptureResult {
        // Trusted copy-on-select source with fresh clipboard activity: the
        // selection is already on the clipboard, and synthesizing would
        // only spend the poll windows proving it again. Consulted before
        // any own write, so the tracker reads pre-capture activity. Falls
        // through on non-text content — the full sequence stays the
        // arbiter of nothingSelected versus failed.
        if sources.shouldFastPath(surface.frontmostAppBundleID), surface.recentClipboardChange() {
            let result = PasteboardCapturePolicy.capturedResult(from: capturedText(on: surface))
            if case .copied = result {
                logger.info("using recently auto-copied clipboard content (known copy-on-select source)")
                return result
            }
            logger.debug("known copy-on-select source held no text content; running full sequence")
        }

        await surface.awaitSynthesisReady()
        guard !Task.isCancelled else { return .failed }

        // Bound after the wait, immediately before synthesis: the HID copy
        // lands in whatever is frontmost NOW, and the retry, the trust
        // record, and the contradiction must all target that app — an app
        // switch during the wait or the poll windows must not misattribute
        // any of them.
        let sourceKey = surface.frontmostAppBundleID
        let sourcePid = surface.frontmostAppPid

        // Snapshot immediately before the copy — taken any earlier, a
        // foreign write during the pre-copy modifier wait would read as
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
            if let pid = sourcePid {
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
            // A landed synthesis is direct disproof of copy-on-select for
            // this source — trusted-until-contradicted, not one
            // observation forever.
            sources.recordContradiction(sourceKey)
            let result = PasteboardCapturePolicy.capturedResult(from: capturedText(on: surface))
            restoreIfSafe(on: surface, snapshot: snapshot, expectedChangeCount: landedCount)
            return result
        }

        // Never consulted on the landed path: `recentClipboardChange`
        // mutates tracker state, and touching it there would lean on the
        // own-writes bracketing staying exactly as wide as it is today.
        // Recent activity plus a dead copy means the clipboard already
        // holds this selection — use it, leave it there, and remember the
        // source so the next capture skips the dead synthesis.
        if surface.recentClipboardChange() {
            let result = PasteboardCapturePolicy.capturedResult(from: capturedText(on: surface))
            if case .copied = result {
                sources.recordAssistSuccess(sourceKey)
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
