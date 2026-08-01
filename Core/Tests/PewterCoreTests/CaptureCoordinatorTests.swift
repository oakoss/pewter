import Foundation
@testable import PewterCore
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
        trusted: Bool = true,
        now: @escaping () -> Date = { Date() }
    ) -> (CaptureCoordinator, ListStore, Outcomes) {
        let store = ListStore()
        let coordinator = CaptureCoordinator(
            store: store,
            selectionReader: reader,
            pasteboardCapture: capture,
            isTrusted: { trusted },
            now: now
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

    @Test func duplicateCaptureInsideTheWindowResurfacesTheExistingNote() throws {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let capture = FakeCapture(result: .failed)
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader,
            capture: capture,
            now: { clock }
        )

        coordinator.captureSelection()
        clock += 1.5
        coordinator.captureSelection()

        #expect(store.items.count == 1)
        let first = try #require(store.items.first)
        #expect(outcomes.all == [.captured(first), .captured(first)])
        // These tests exercise the synchronous AX path only.
        #expect(capture.callCount == 0)
    }

    @Test func duplicateGuardAlsoCoversThePasteboardFallback() async throws {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied("fallback text"))
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader,
            capture: capture,
            now: { clock }
        )

        coordinator.captureSelection()
        try await waitUntil { outcomes.all.count == 1 }
        clock += 1
        coordinator.captureSelection()
        try await waitUntil { outcomes.all.count == 2 }

        #expect(store.items.count == 1)
    }

    @Test func whitespaceRecaptureInsideTheWindowStaysNothingSelected() {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "real note")
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        clock += 1
        reader.result = "   "
        coordinator.captureSelection()

        // Whitespace must fall through to .nothingSelected — the guard
        // must never match it against a stored note.
        #expect(store.items.count == 1)
        #expect(outcomes.all.last == .nothingSelected)
    }

    @Test func duplicateAtTheWindowBoundariesIsSuppressed() {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        // Same instant: the exact double-fire the guard exists for.
        coordinator.captureSelection()
        coordinator.captureSelection()
        #expect(store.items.count == 1)

        clock += 2
        coordinator.captureSelection()
        #expect(store.items.count == 1)
    }

    @Test func backwardClockAdjustmentDoesNotSuppressCaptures() {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        clock -= 60
        coordinator.captureSelection()

        #expect(store.items.count == 2)
    }

    @Test func editedNoteInsideTheWindowIsCapturedFresh() throws {
        // The guard compares the stored note's current text, so editing it
        // opts out of deduplication — an edited note is no longer a
        // duplicate of what's on screen.
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        let first = try #require(store.items.first)
        store.updateText(id: first.id, text: "edited")
        clock += 1
        coordinator.captureSelection()

        #expect(store.items.map(\.text) == ["edited", "same selection"])
    }

    @Test func duplicateGuardComparesNormalizedText() {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "  padded  ")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        clock += 1
        reader.result = "padded"
        coordinator.captureSelection()

        #expect(store.items.count == 1)
    }

    @Test func captureOutsideTheWindowAddsAgain() {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        clock += 2.5
        coordinator.captureSelection()

        #expect(store.items.count == 2)
    }

    @Test func duplicateDoesNotExtendTheWindow() {
        // The window is measured from the last added note, so a chain of
        // duplicates cannot suppress captures forever.
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        clock += 1.5
        coordinator.captureSelection()
        #expect(store.items.count == 1)
        clock += 1
        coordinator.captureSelection()
        #expect(store.items.count == 2)
    }

    @Test func differentTextInsideTheWindowAdds() {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "first")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        clock += 0.5
        reader.result = "second"
        coordinator.captureSelection()

        #expect(store.items.count == 2)
    }

    @Test func deletedNoteInsideTheWindowIsCapturedFresh() throws {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: "same selection")
        let (coordinator, store, _) = makeCoordinator(
            reader: reader,
            capture: FakeCapture(result: .failed),
            now: { clock }
        )

        coordinator.captureSelection()
        let first = try #require(store.items.first)
        store.delete(ids: [first.id])
        clock += 1
        coordinator.captureSelection()

        // The user deleted it on purpose; the guard must not resurrect it
        // or swallow the new capture.
        #expect(store.items.count == 1)
        #expect(store.items.first?.id != first.id)
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
        // Different text so the duplicate-capture guard stays out of the
        // in-flight guard's test.
        capture.shouldSuspend = false
        capture.result = .copied("second text")
        coordinator.captureSelection()
        try await waitUntil { outcomes.all.count == 2 }
        #expect(store.items.count == 2)
    }

    @Test func captureAtTheCapPassesThroughUntouched() {
        let text = String(repeating: "a", count: CaptureCoordinator.captureLengthCap)
        let reader = FakeReader(result: text)
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(store.items.map(\.text) == [text])
    }

    @Test func overCapCaptureTruncatesToTheCapWithEllipsis() {
        let reader = FakeReader(result: String(repeating: "a", count: 30000))
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        let stored = store.items[0].text
        #expect(stored.count == CaptureCoordinator.captureLengthCap)
        #expect(stored.hasSuffix("a…"))
    }

    @Test func truncationDropsAWholeGraphemeAtTheCut() {
        // A ZWJ family emoji is one Character across many scalars; the cut
        // must drop or keep it whole, never split it into parts.
        let text = String(repeating: "a", count: CaptureCoordinator.captureLengthCap - 2)
            + "👨‍👩‍👧‍👦" + String(repeating: "b", count: 100)
        let reader = FakeReader(result: text)
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        let stored = store.items[0].text
        #expect(stored.hasSuffix("👨‍👩‍👧‍👦…"))
        #expect(stored.count == CaptureCoordinator.captureLengthCap)
    }

    @Test func truncationTrimsWhitespaceBeforeTheEllipsis() {
        let head = String(repeating: "a", count: CaptureCoordinator.captureLengthCap - 10)
        let reader = FakeReader(result: head + String(repeating: " ", count: 100))
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(store.items.map(\.text) == [head + "…"])
    }

    @Test func whitespaceOnlyOverCapCaptureReportsNothingSelected() {
        let reader = FakeReader(result: String(repeating: " ", count: 30000))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(store.items.isEmpty)
        #expect(outcomes.all == [.nothingSelected])
    }

    @Test func oneOverTheCapTruncates() {
        let reader = FakeReader(result: String(repeating: "a", count: CaptureCoordinator.captureLengthCap + 1))
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(store.items[0].text.count == CaptureCoordinator.captureLengthCap)
        #expect(store.items[0].text.hasSuffix("…"))
    }

    @Test func contentBehindALongWhitespaceRunSurvivesTheCap() {
        let reader = FakeReader(result: String(repeating: " ", count: 25000) + "content")
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(store.items.map(\.text) == ["content"])
    }

    @Test func pasteboardFallbackCaptureIsCapped() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied(String(repeating: "a", count: 30000)))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(store.items[0].text.count == CaptureCoordinator.captureLengthCap)
        #expect(store.items[0].text.hasSuffix("a…"))
    }

    @Test func combiningMarkRunsAreCappedByBytes() {
        // Each character is one base scalar plus ten combining marks — few
        // characters, many bytes. The byte cap must bound these; the
        // character cap alone would wave them through.
        let zalgo = "e" + String(repeating: "\u{0301}", count: 10)
        let reader = FakeReader(result: String(repeating: zalgo, count: 15000))
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        let stored = store.items[0].text
        #expect(stored.utf8.count <= CaptureCoordinator.captureByteCap)
        #expect(stored.count < CaptureCoordinator.captureLengthCap)
        #expect(stored.hasSuffix("…"))
    }

    @Test func truncationInsideAFencedBlockClosesTheFence() {
        let code = "```\n" + String(repeating: "code line\n", count: 4000) + "```"
        let reader = FakeReader(result: code)
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        let stored = store.items[0].text
        #expect(stored.count <= CaptureCoordinator.captureLengthCap)
        #expect(stored.hasSuffix("…\n```"))
    }

    @Test func truncationClosesASizedFenceWithItsOwnDelimiter() {
        // A backtick run inside the block is content, not a closer — the
        // appended close must match the four-tick opener.
        let code = "````\n" + String(repeating: "``` inner\n", count: 4000) + "````"
        let reader = FakeReader(result: code)
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        let stored = store.items[0].text
        #expect(stored.count <= CaptureCoordinator.captureLengthCap)
        #expect(stored.hasSuffix("…\n````"))
    }

    @Test func indentedFenceCloserIsRecognizedNotRepaired() {
        // The fence is already closed (an up-to-3-space indented closer is
        // legal); the repair must not append a spurious opener.
        let text = "```\ncode\n  ```\n" + String(repeating: "prose ", count: 4000)
        let reader = FakeReader(result: text)
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        let stored = store.items[0].text
        let fenceLines = stored.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .count { $0.drop(while: { $0 == " " }).hasPrefix("```") }
        #expect(fenceLines == 2)
        #expect(stored.hasSuffix("…"))
    }

    @Test func duplicateGuardCoversTruncatedCaptures() {
        let reader = FakeReader(result: String(repeating: "a", count: 25000))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()
        coordinator.captureSelection()

        #expect(store.items.count == 1)
        #expect(outcomes.all.count == 2)
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
