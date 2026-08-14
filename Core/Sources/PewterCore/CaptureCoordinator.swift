import CoreGraphics
import Foundation
import os

/// One Accessibility read. Anchors are AppKit bottom-left globals; nil
/// means the app exposed no usable geometry and feedback should anchor on
/// the mouse instead.
public enum SelectionRead: Equatable, Sendable {
    /// A non-empty selection and, when available, its screen bounds.
    case selection(text: String, bounds: CGRect?)
    /// No selection; `caret` still marks where the user is working.
    case noSelection(caret: CGRect?)
}

public protocol SelectionReading {
    @MainActor func readSelection() -> SelectionRead
}

public enum PasteboardCaptureResult: Equatable, Sendable {
    case copied(String)
    case nothingSelected
    /// The capture machinery itself failed (event synthesis, etc.) —
    /// distinct from "no selection" so the user isn't sent debugging the
    /// wrong thing.
    case failed
}

public protocol PasteboardCapturing {
    @MainActor func capture() async -> PasteboardCaptureResult
}

/// Orchestrates a capture: trigger → AX read → pasteboard fallback → store.
/// Dependencies are protocols so this flow is testable with fakes.
@MainActor
public final class CaptureCoordinator {
    /// Anchors ride the outcome so feedback lands where the capture
    /// happened, read once by the same pass that produced the text — a
    /// second AX read after the capture would race the frontmost app's
    /// state. Pasteboard-tier captures carry nil (no AX element by
    /// construction). A failed capture carries none structurally: even a
    /// rescue read's caret is discarded there, because failure feedback
    /// must not anchor on an app that may be unresponsive.
    public enum Outcome: Equatable {
        case captured(Item, anchor: CGRect?)
        case nothingSelected(anchor: CGRect?)
        case captureFailed
        case notPermitted
        /// The capture succeeded but the text would not have reached disk.
        /// The reason rides along because the remedies differ — repair the
        /// file, or simply capture again.
        case notesUnavailable(Unavailability)
    }

    public var onOutcome: ((Outcome) -> Void)?

    /// Every capture leaves a breadcrumb — counts and tier names only,
    /// never content. Without one, a diagnostics report can't distinguish
    /// "capture ran cleanly" from "the gesture never arrived".
    private static let logger = Logger.capture

    /// Consecutive captures of the same text within this window are
    /// accidental duplicates (a double-tap firing twice on one selection).
    /// The window is measured from the last *added* note — a duplicate does
    /// not extend it, so a chain of re-fires can't suppress captures
    /// forever.
    private static let duplicateWindow: TimeInterval = 2.0

    /// A stray select-all can capture huge text into a hand-editable file.
    /// Only captures are capped — the composer, the editor, and external
    /// edits are deliberate and never truncated.
    static let captureLengthCap = 20000

    /// A single Character can carry an unbounded run of combining scalars,
    /// so the character cap alone can't bound the file's size on disk;
    /// bytes back it up.
    static let captureByteCap = 100_000

    /// Caps `text` to `captureLengthCap` characters and `captureByteCap`
    /// UTF-8 bytes, ellipsis included, cutting on Character boundaries so a
    /// grapheme at the cap is dropped whole. Leading whitespace is dropped
    /// before measuring — it's trimmed downstream anyway, and letting it eat
    /// the budget would discard the content behind it. Bounded prefixes keep
    /// both checks O(cap) even on bridged strings, where a plain count walks
    /// the whole selection.
    static func capped(_ text: String) -> String {
        let head = text.drop(while: \.isWhitespace)
        let overChars = head.prefix(captureLengthCap + 1).count > captureLengthCap
        let overBytes = head.utf8.prefix(captureByteCap + 1).count > captureByteCap
        guard overChars || overBytes else { return text }

        var cut = String(head.prefix(captureLengthCap - 1))
        while cut.utf8.count > captureByteCap - "…".utf8.count {
            cut.removeLast()
        }
        while let last = cut.last, last.isWhitespace {
            cut.removeLast()
        }
        // Rich captures arrive as Markdown; a cut landing inside a fenced
        // code block would leave the fence open and mis-render everything
        // after it in an external editor. Close it, inside the budget.
        if let fence = MarkdownFence.openDelimiter(in: cut) {
            // Clamped targets, not subtraction: a pathological opener can be
            // longer than the whole budget, and an unclamped removeLast
            // would trap. An empty cut is the degenerate answer there.
            let target = max(0, captureLengthCap - fence.count - 2)
            if cut.count > target {
                cut.removeLast(cut.count - target)
            }
            // The close is appended after the byte trim above spent the
            // budget; reserve its bytes too.
            let byteTarget = max(0, captureByteCap - fence.utf8.count - 1 - "…".utf8.count)
            while !cut.isEmpty, cut.utf8.count > byteTarget {
                cut.removeLast()
            }
            if let fence = MarkdownFence.openDelimiter(in: cut) {
                // Ellipsis inside the block, fence last — a closing fence
                // trailed by anything but spaces isn't a closer at all.
                return cut + "…\n" + fence
            }
        }
        return cut + "…"
    }

    private let store: ListStore
    private let selectionReader: any SelectionReading
    private let pasteboardCapture: any PasteboardCapturing
    private let isTrusted: () -> Bool
    private let prefersRichSource: () -> Bool
    private let now: () -> Date
    private var captureInFlight = false
    private var lastCapture: (itemID: UUID, at: Date)?

    public init(
        store: ListStore,
        selectionReader: any SelectionReading,
        pasteboardCapture: any PasteboardCapturing,
        isTrusted: @escaping () -> Bool,
        prefersRichSource: @escaping () -> Bool = { false },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.selectionReader = selectionReader
        self.pasteboardCapture = pasteboardCapture
        self.isTrusted = isTrusted
        self.prefersRichSource = prefersRichSource
        self.now = now
    }

    public func captureSelection() {
        guard isTrusted() else {
            Self.logger.info("capture blocked: accessibility not granted")
            onOutcome?(.notPermitted)
            return
        }
        guard !captureInFlight else {
            Self.logger.debug("capture ignored: one already in flight")
            return
        }

        // Rich sources (browsers) invert the tiers: their pasteboard flavor
        // keeps formatting the AX read flattens — and their AX selection
        // mashes block boundaries — so the AX read demotes to a rescue.
        if prefersRichSource() {
            runPasteboardTier(rescuingWithSelectionReader: true, caretAnchor: nil)
            return
        }

        switch selectionReader.readSelection() {
        case let .selection(text, bounds):
            finish(with: text, anchor: bounds, noTextAnchor: bounds, via: "selection")
        case let .noSelection(caret):
            // The caret is still the right spot for nothing-selected
            // feedback if the fallback comes up empty too. It can be a few
            // hundred ms stale by then (the pasteboard tier runs in
            // between); the HUD's screen re-resolution and clamping bound
            // the drift.
            runPasteboardTier(rescuingWithSelectionReader: false, caretAnchor: caret)
        }
    }

    private func runPasteboardTier(rescuingWithSelectionReader rescue: Bool, caretAnchor: CGRect?) {
        captureInFlight = true
        Task { [weak self] in
            // Holding only the capture dependency across the await keeps a
            // deallocated coordinator from being kept alive by an in-flight
            // capture, and the result non-optional.
            guard let capture = self?.pasteboardCapture else { return }
            let result = await capture.capture()
            guard let self else { return }
            captureInFlight = false
            switch result {
            case let .copied(text):
                // Clipboard text carries no AX anchor, but if it turns out
                // to be whitespace-only the outcome is "nothing selected"
                // — exactly what the pre-read caret exists to place.
                finish(
                    with: text,
                    anchor: nil,
                    noTextAnchor: caretAnchor,
                    via: rescue ? "pasteboard (rich source)" : "pasteboard"
                )
            case .nothingSelected:
                switch rescue ? selectionReader.readSelection() : .noSelection(caret: caretAnchor) {
                case let .selection(text, bounds):
                    finish(with: text, anchor: bounds, noTextAnchor: bounds, via: "selection rescue")
                case let .noSelection(caret):
                    Self.logger.info("capture ended: nothing selected")
                    onOutcome?(.nothingSelected(anchor: caret))
                }
            case .failed:
                if rescue, case let .selection(text, bounds) = selectionReader.readSelection() {
                    finish(with: text, anchor: bounds, noTextAnchor: bounds, via: "selection rescue")
                } else {
                    // The failing step already logged its own error; this is
                    // the sequence marker.
                    Self.logger.info("capture ended: pasteboard tier failed")
                    onOutcome?(.captureFailed)
                }
            }
        }
    }

    /// `anchor` rides a successful capture; `noTextAnchor` places the
    /// nothing-selected feedback when the text turns out to be
    /// whitespace-only — the two can differ on the pasteboard tier, where
    /// clipboard text has no AX anchor but the pre-read caret still marks
    /// where the user is working.
    private func finish(with text: String, anchor: CGRect?, noTextAnchor: CGRect?, via tier: String) {
        // Cap before the duplicate check: the stored note holds capped text,
        // and comparing raw text against it would let a re-fired over-cap
        // capture slip past the guard.
        let text = Self.capped(text)
        if let existing = duplicate(of: text) {
            // Re-surface the existing note instead of adding a copy — the
            // double-fire reads as one successful capture, not a silent
            // no-op. Ahead of the availability guard on purpose: nothing new
            // is stored, so there is nothing to discard.
            Self.logger.info("duplicate capture via \(tier, privacy: .public) tier; re-surfacing the existing note")
            onOutcome?(.captured(existing, anchor: anchor))
            return
        }
        // A refused capture is its own retry, in both broken states: a
        // permission-only repair fires no watcher event, and with the panel
        // closed nothing else re-reads the file. Without this the user is
        // told their notes are unreadable until they relaunch.
        store.retryUnavailableStorage()
        // The panel is closed during a capture, so the HUD is the only signal
        // the user gets — a note added to a document whose file turned
        // unreadable never reaches disk, and reporting "Captured" for that is
        // the lie to avoid. The store decides and names the reason.
        switch store.add(text: text) {
        case let .applied(item):
            lastCapture = (item.id, now())
            Self.logger.info("captured \(text.count) chars via \(tier, privacy: .public) tier")
            onOutcome?(.captured(item, anchor: anchor))
        case .unchanged:
            // `add` returns `.unchanged` for whitespace-only input and nothing
            // else (see its doc), which is what lets this map to "nothing
            // selected" rather than having to ask why.
            Self.logger.info("capture ended: whitespace-only text via \(tier, privacy: .public) tier")
            onOutcome?(.nothingSelected(anchor: noTextAnchor))
        case let .refused(reason):
            // Default privacy, not `.public`: `.other` carries the system's
            // description, which can name the notes file's path. Copy
            // Diagnostics reads our own store, where this still renders
            // verbatim and its home prefix is scrubbed on the way out.
            let cause = reason.logDescription
            Self.logger.error("capture discarded: \(text.count) chars had nowhere to go — \(cause)")
            onOutcome?(.notesUnavailable(reason))
        }
    }

    /// The just-captured note, when `text` matches it inside the window.
    /// Comparison is against the stored item's normalized text so raw
    /// selection whitespace can't defeat the guard, and a note the user
    /// already deleted or edited is never resurrected.
    private func duplicate(of text: String) -> Item? {
        guard let lastCapture,
              // Range, not <=: a backward clock adjustment (NTP sync) makes
              // the interval negative and must not suppress captures until
              // wall time catches up.
              (0 ... Self.duplicateWindow).contains(now().timeIntervalSince(lastCapture.at)),
              let existing = store.items.first(where: { $0.id == lastCapture.itemID }),
              existing.text == Item(text: text).text
        else { return nil }
        return existing
    }
}
