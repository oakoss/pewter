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

    private let store: ListStore
    private let selectionReader: any SelectionReading
    private let pasteboardCapture: any PasteboardCapturing
    private let isTrusted: () -> Bool
    private var captureInFlight = false

    public init(
        store: ListStore,
        selectionReader: any SelectionReading,
        pasteboardCapture: any PasteboardCapturing,
        isTrusted: @escaping () -> Bool
    ) {
        self.store = store
        self.selectionReader = selectionReader
        self.pasteboardCapture = pasteboardCapture
        self.isTrusted = isTrusted
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
        if let item = store.add(text: text) {
            onOutcome?(.captured(item))
        } else {
            onOutcome?(.nothingSelected)
        }
    }
}
