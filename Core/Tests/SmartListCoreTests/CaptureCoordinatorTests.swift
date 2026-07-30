import Foundation
@testable import SmartListCore
import Testing

@MainActor
private final class FakeReader: SelectionReading {
    var result: String?
    var callCount = 0
    init(result: String?) {
        self.result = result
    }

    func readSelection() -> String? {
        callCount += 1
        return result
    }
}

@MainActor
private final class FakeCapture: PasteboardCapturing {
    var result: PasteboardCaptureResult
    var callCount = 0
    var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: PasteboardCaptureResult) {
        self.result = result
    }

    func capture() async -> PasteboardCaptureResult {
        callCount += 1
        if shouldSuspend {
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    func resumeGate() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct CaptureCoordinatorTests {
    private func makeCoordinator(
        reader: FakeReader,
        capture: FakeCapture,
        trusted: Bool = true
    ) -> (CaptureCoordinator, ListStore, Outcomes) {
        let store = ListStore()
        let coordinator = CaptureCoordinator(
            store: store,
            selectionReader: reader,
            pasteboardCapture: capture,
            isTrusted: { trusted }
        )
        let outcomes = Outcomes()
        coordinator.onOutcome = { outcomes.record($0) }
        return (coordinator, store, outcomes)
    }

    @Test func untrustedReportsNotPermittedWithoutTouchingDeps() {
        let reader = FakeReader(result: "text")
        let capture = FakeCapture(result: .copied("text"))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture, trusted: false)

        coordinator.captureSelection()

        #expect(outcomes.all == [.notPermitted])
        #expect(reader.callCount == 0)
        #expect(capture.callCount == 0)
        #expect(store.items.isEmpty)
    }

    @Test func accessibilityHitSkipsPasteboardFallback() {
        let reader = FakeReader(result: "from AX")
        let capture = FakeCapture(result: .copied("should not be used"))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()

        #expect(store.items.map(\.text) == ["from AX"])
        #expect(capture.callCount == 0)
        #expect(outcomes.all.count == 1)
        if case let .captured(item) = outcomes.all[0] {
            #expect(item.text == "from AX")
        } else {
            Issue.record("expected .captured, got \(outcomes.all)")
        }
    }

    @Test func accessibilityMissFallsBackToPasteboard() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied("from clipboard"))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(store.items.map(\.text) == ["from clipboard"])
        #expect(capture.callCount == 1)
    }

    @Test func bothPathsEmptyReportsNothingSelected() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .nothingSelected)
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.nothingSelected])
        #expect(store.items.isEmpty)
    }

    @Test func whitespaceOnlyCaptureReportsNothingSelected() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied("   \n  "))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.nothingSelected])
        #expect(store.items.isEmpty)
    }

    @Test func synthesisFailureReportsCaptureFailed() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .failed)
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.captureFailed])
    }

    @Test func secondCaptureWhileFallbackInFlightIsDropped() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied("only once"))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        // Suspend the first capture so the second arrives mid-flight.
        capture.shouldSuspend = true
        coordinator.captureSelection()
        try await waitUntil { capture.callCount == 1 }

        coordinator.captureSelection()
        #expect(capture.callCount == 1)

        capture.resumeGate()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(store.items.count == 1)
        #expect(outcomes.all.count == 1)

        // The in-flight guard must reset — if it stayed latched, every
        // capture after the first fallback would be silently dropped.
        capture.shouldSuspend = false
        coordinator.captureSelection()
        try await waitUntil { outcomes.all.count == 2 }
        #expect(store.items.count == 2)
    }
}

/// Outcome accumulator (MainActor-confined, so a plain class is fine).
@MainActor
private final class Outcomes {
    private(set) var all: [CaptureCoordinator.Outcome] = []
    func record(_ outcome: CaptureCoordinator.Outcome) {
        all.append(outcome)
    }
}

private struct WaitTimeout: Error {}

/// Throws on timeout so follow-up expectations don't fail for cascading
/// reasons — the root cause stays the only failure in the output.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for condition")
            throw WaitTimeout()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
