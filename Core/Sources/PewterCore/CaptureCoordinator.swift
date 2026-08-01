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
