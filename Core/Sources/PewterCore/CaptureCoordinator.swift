import Foundation

public protocol SelectionReading {
    @MainActor func readSelection() -> String?
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
    public enum Outcome: Equatable {
        case captured(Item)
        case nothingSelected
        case captureFailed
        case notPermitted
    }

    public var onOutcome: ((Outcome) -> Void)?

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
        if let fence = openFenceDelimiter(in: cut) {
            let over = cut.count - (captureLengthCap - fence.count - 2)
            if over > 0 {
                cut.removeLast(over)
            }
            // The close is appended after the byte trim above spent the
            // budget; reserve its bytes too.
            let tail = fence.utf8.count + 1 + "…".utf8.count
            while cut.utf8.count > captureByteCap - tail {
                cut.removeLast()
            }
            if let fence = openFenceDelimiter(in: cut) {
                // Ellipsis inside the block, fence last — a closing fence
                // trailed by anything but spaces isn't a closer at all.
                return cut + "…\n" + fence
            }
        }
        return cut + "…"
    }

    /// The delimiter of a fence left open in `text`, nil when every fence
    /// is closed. Per CommonMark a fence line may be indented up to three
    /// spaces, and a closer must be at least as long as its opener — a
    /// shorter backtick run inside the block is content.
    private static func openFenceDelimiter(in text: String) -> String? {
        var open = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let body = line.drop(while: { $0 == " " })
            guard line.count - body.count <= 3, body.hasPrefix("```") else { continue }
            let ticks = body.prefix(while: { $0 == "`" }).count
            if open == 0 {
                open = ticks
            } else if ticks >= open {
                open = 0
            }
        }
        return open > 0 ? String(repeating: "`", count: open) : nil
    }

    private let store: ListStore
    private let selectionReader: any SelectionReading
    private let pasteboardCapture: any PasteboardCapturing
    private let isTrusted: () -> Bool
    private let now: () -> Date
    private var captureInFlight = false
    private var lastCapture: (itemID: UUID, at: Date)?

    public init(
        store: ListStore,
        selectionReader: any SelectionReading,
        pasteboardCapture: any PasteboardCapturing,
        isTrusted: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.selectionReader = selectionReader
        self.pasteboardCapture = pasteboardCapture
        self.isTrusted = isTrusted
        self.now = now
    }

    public func captureSelection() {
        guard isTrusted() else {
            onOutcome?(.notPermitted)
            return
        }
        guard !captureInFlight else { return }

        if let text = selectionReader.readSelection() {
            finish(with: text)
            return
        }

        captureInFlight = true
        Task { [weak self] in
            let result = await self?.pasteboardCapture.capture()
            guard let self else { return }
            captureInFlight = false
            switch result {
            case let .copied(text):
                finish(with: text)
            case .nothingSelected, nil:
                onOutcome?(.nothingSelected)
            case .failed:
                onOutcome?(.captureFailed)
            }
        }
    }

    private func finish(with text: String) {
        // Cap before the duplicate check: the stored note holds capped text,
        // and comparing raw text against it would let a re-fired over-cap
        // capture slip past the guard.
        let text = Self.capped(text)
        if let existing = duplicate(of: text) {
            // Re-surface the existing note instead of adding a copy — the
            // double-fire reads as one successful capture, not a silent
            // no-op.
            onOutcome?(.captured(existing))
            return
        }
        if let item = store.add(text: text) {
            lastCapture = (item.id, now())
            onOutcome?(.captured(item))
        } else {
            onOutcome?(.nothingSelected)
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
