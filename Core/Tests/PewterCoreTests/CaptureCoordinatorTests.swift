import Foundation
@testable import PewterCore
import Testing

@MainActor
private final class FakeReader: SelectionReading {
    var result: String?
    var anchor: CGRect?
    var callCount = 0
    init(result: String?, anchor: CGRect? = nil) {
        self.result = result
        self.anchor = anchor
    }

    func readSelection() -> SelectionRead {
        callCount += 1
        if let result {
            return .selection(text: result, bounds: anchor)
        }
        return .noSelection(caret: anchor)
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
        prefersRichSource: Bool = false,
        store: ListStore = ListStore(),
        now: @escaping () -> Date = { Date() }
    ) -> (CaptureCoordinator, ListStore, Outcomes) {
        let coordinator = CaptureCoordinator(
            store: store,
            selectionReader: reader,
            pasteboardCapture: capture,
            isTrusted: { trusted },
            prefersRichSource: { prefersRichSource },
            now: now
        )
        let outcomes = Outcomes()
        coordinator.onOutcome = { outcomes.record($0) }
        return (coordinator, store, outcomes)
    }

    /// A capture-only user never opens the panel, so without a retry here a
    /// repaired file would go unnoticed and every capture would keep failing.
    @Test func captureRetriesTheFileAndSucceedsOnceItIsReadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-capture-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.documentIsPlaceholder)

        try Data("- [ ] repaired\n".utf8).write(to: url, options: .atomic)

        let reader = FakeReader(result: "captured after repair")
        let capture = FakeCapture(result: .copied("should not be used"))
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture, store: store)
        coordinator.captureSelection()

        #expect(store.items.map(\.text) == ["repaired", "captured after repair"])
        #expect(outcomes.all.count == 1)
        if case .captured = outcomes.all[0] {} else {
            Issue.record("expected .captured, got \(outcomes.all)")
        }
    }

    /// A file that turns unreadable while the app runs leaves the real notes
    /// in memory, so nothing looks wrong — but the save is refused and the
    /// note dies at quit. Reporting "Captured" there is the lie the guard
    /// exists to prevent, and the panel is closed so the HUD is the only
    /// signal the user gets.
    @Test func captureIsRefusedWhenSavingIsSuspendedAtRuntime() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-capture-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()
        #expect(!store.documentIsPlaceholder)

        // Unreadable now, with the user's real document still in memory.
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.flush()
        #expect(storage.health == .unreadable(cause: .notUTF8))
        #expect(!store.documentIsPlaceholder)

        let reader = FakeReader(result: "captured during a suspension")
        let capture = FakeCapture(result: .copied("should not be used"))
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture, store: store)
        coordinator.captureSelection()

        #expect(outcomes.all == [.notesUnavailable(.unreadable(cause: .notUTF8))])
        #expect(store.items.map(\.text) == ["a real note"])
    }

    /// The residual half of the adoption problem: an adoption the capture did
    /// not trigger has already happened, so there is nothing to drain and the
    /// store stays behind until the delivery lands. The capture is refused —
    /// correctly, the note would be replaced — but the file reads perfectly,
    /// and reporting "can't read your notes file" sent the user to check
    /// permissions when the remedy was to press the key again.
    @Test func aCaptureRefusedForAnAdoptionDoesNotBlameTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-capture-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()

        // Adopted by the save itself, not by the capture's retry, so the
        // capture finds the store behind with nothing to rebase it.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)
        store.flush()

        let reader = FakeReader(result: "captured into the handoff window")
        let capture = FakeCapture(result: .copied("should not be used"))
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture, store: store)
        coordinator.captureSelection()

        #expect(storage.health == .ok, "the file reads perfectly throughout")
        #expect(outcomes.all == [.notesUnavailable(.adoptionInFlight)])
    }

    /// An external edit the app never saw makes the capture's own retry adopt
    /// it, which leaves the store a generation behind. Refusing there reported
    /// "Can't read your notes file" about a file that reads perfectly, sending
    /// the user to fix permissions when the remedy was to capture again. The
    /// retry drains the adoption instead, so the capture lands on top of it.
    @Test func aCaptureThatTriggersAnAdoptionIsNotBlamedOnTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-capture-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()

        try Data("- [ ] edited outside\n".utf8).write(to: url, options: .atomic)

        let reader = FakeReader(result: "captured after an outside edit")
        let capture = FakeCapture(result: .copied("should not be used"))
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture, store: store)
        coordinator.captureSelection()

        #expect(outcomes.all.count == 1)
        if case .notesUnavailable = try #require(outcomes.all.first) {
            Issue.record("the file is readable; the capture must not blame it")
        }
        #expect(store.items.map(\.text) == ["edited outside", "captured after an outside edit"])
    }

    /// The capture text was read fine — there is simply nowhere to put it.
    /// Storing it anyway would add to a document that gets replaced the
    /// moment the real notes are read, so it fails where the user can see it.
    @Test func captureIsRefusedWhileTheDocumentIsAPlaceholder() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-capture-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.documentIsPlaceholder)

        let reader = FakeReader(result: "captured while unreadable")
        let capture = FakeCapture(result: .copied("should not be used"))
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture, store: store)
        coordinator.captureSelection()

        #expect(outcomes.all == [.notesUnavailable(.unreadable(cause: .notUTF8))])
        #expect(store.items.isEmpty)
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
        if case let .captured(item, _) = outcomes.all[0] {
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

        #expect(outcomes.all == [.nothingSelected(anchor: nil)])
        #expect(store.items.isEmpty)
    }

    @Test func whitespaceOnlyCaptureReportsNothingSelected() async throws {
        let caret = CGRect(x: 5, y: 5, width: 0, height: 18)
        let reader = FakeReader(result: nil, anchor: caret)
        let capture = FakeCapture(result: .copied("   \n  "))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        // The outcome is "nothing selected", which is exactly what the
        // pre-read caret exists to place — whitespace-only clipboard text
        // must not demote the feedback to the mouse.
        #expect(outcomes.all == [.nothingSelected(anchor: caret)])
        #expect(store.items.isEmpty)
    }

    @Test func selectionCaptureCarriesTheReadersAnchor() throws {
        let anchor = CGRect(x: 10, y: 20, width: 100, height: 18)
        let reader = FakeReader(result: "from AX", anchor: anchor)
        let capture = FakeCapture(result: .copied("unused"))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()

        let item = try #require(store.items.first)
        #expect(outcomes.all == [.captured(item, anchor: anchor)])
    }

    @Test func pasteboardCaptureCarriesNoAnchor() async throws {
        // The caret anchor from the failed AX read must not leak onto a
        // pasteboard capture — that text came from somewhere else.
        let reader = FakeReader(result: nil, anchor: CGRect(x: 5, y: 5, width: 0, height: 18))
        let capture = FakeCapture(result: .copied("from clipboard"))
        let (coordinator, store, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        let item = try #require(store.items.first)
        #expect(outcomes.all == [.captured(item, anchor: nil)])
    }

    @Test func nothingSelectedCarriesTheCaretAnchor() async throws {
        let caret = CGRect(x: 5, y: 5, width: 0, height: 18)
        let reader = FakeReader(result: nil, anchor: caret)
        let capture = FakeCapture(result: .nothingSelected)
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.nothingSelected(anchor: caret)])
    }

    @Test func whitespaceOnlySelectionCarriesTheAnchor() {
        let anchor = CGRect(x: 10, y: 20, width: 40, height: 18)
        let reader = FakeReader(result: "   ", anchor: anchor)
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(outcomes.all == [.nothingSelected(anchor: anchor)])
    }

    @Test func synthesisFailureReportsCaptureFailed() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .failed)
        let (coordinator, _, outcomes) = makeCoordinator(reader: reader, capture: capture)

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.captureFailed])
        // Exactly one AX read: the default path must not rescue — a second
        // read after the pasteboard tier would be a redundant window walk.
        #expect(reader.callCount == 1)
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

        let firstAnchor = CGRect(x: 10, y: 10, width: 50, height: 18)
        reader.anchor = firstAnchor
        coordinator.captureSelection()
        clock += 1.5
        // The re-surfaced duplicate carries the CURRENT attempt's anchor —
        // the user may have scrolled since the first capture.
        let secondAnchor = CGRect(x: 10, y: 300, width: 50, height: 18)
        reader.anchor = secondAnchor
        coordinator.captureSelection()

        #expect(store.items.count == 1)
        let first = try #require(store.items.first)
        #expect(outcomes.all == [.captured(first, anchor: firstAnchor), .captured(first, anchor: secondAnchor)])
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
        #expect(outcomes.all.last == .nothingSelected(anchor: nil))
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

        // Post-await: a second Task the guard failed to drop would have run
        // by now — the synchronous check above can't see an enqueued one.
        #expect(capture.callCount == 1)
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

    @Test func untrustedRichSourceReportsNotPermittedWithoutFiringTiers() {
        let reader = FakeReader(result: "text")
        let capture = FakeCapture(result: .copied("text"))
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, trusted: false, prefersRichSource: true
        )

        coordinator.captureSelection()

        #expect(outcomes.all == [.notPermitted])
        #expect(capture.callCount == 0)
        #expect(reader.callCount == 0)
        #expect(store.items.isEmpty)
    }

    @Test func secondRichSourceCaptureWhileInFlightIsDropped() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied("rich"))
        capture.shouldSuspend = true
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true
        )

        coordinator.captureSelection()
        try await waitUntil { capture.callCount == 1 }
        coordinator.captureSelection()
        #expect(capture.callCount == 1)

        capture.resumeGate()
        try await waitUntil { !outcomes.all.isEmpty }
        // Post-await: a second Task the guard failed to drop would have run
        // by now — the synchronous check above can't see an enqueued one.
        #expect(capture.callCount == 1)
        #expect(store.items.count == 1)
    }

    @Test func richSourcePrefersThePasteboardOverAX() async throws {
        let reader = FakeReader(result: "plain from AX", anchor: CGRect(x: 1, y: 2, width: 3, height: 4))
        let capture = FakeCapture(result: .copied("**rich** from pasteboard"))
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true
        )

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(store.items.map(\.text) == ["**rich** from pasteboard"])
        #expect(reader.callCount == 0)
        let item = try #require(store.items.first)
        #expect(outcomes.all == [.captured(item, anchor: nil)])
    }

    @Test func richSourceRescuesWithAXWhenPasteboardIsEmpty() async throws {
        let anchor = CGRect(x: 40, y: 50, width: 120, height: 18)
        let reader = FakeReader(result: "ax rescue", anchor: anchor)
        let capture = FakeCapture(result: .nothingSelected)
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true
        )

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(store.items.map(\.text) == ["ax rescue"])
        let item = try #require(store.items.first)
        #expect(outcomes.all == [.captured(item, anchor: anchor)])
    }

    @Test func richSourceRescuesWithAXOnCaptureFailure() async throws {
        let anchor = CGRect(x: 40, y: 50, width: 120, height: 18)
        let reader = FakeReader(result: "ax rescue", anchor: anchor)
        let capture = FakeCapture(result: .failed)
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true
        )

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(store.items.map(\.text) == ["ax rescue"])
        let item = try #require(store.items.first)
        #expect(outcomes.all == [.captured(item, anchor: anchor)])
    }

    @Test func richSourceWithNothingAnywhereReportsNothingSelected() async throws {
        let caret = CGRect(x: 40, y: 50, width: 0, height: 18)
        let reader = FakeReader(result: nil, anchor: caret)
        let capture = FakeCapture(result: .nothingSelected)
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true
        )

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.nothingSelected(anchor: caret)])
        #expect(store.items.isEmpty)
    }

    @Test func richSourceFailureWithNoSelectionReportsCaptureFailed() async throws {
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .failed)
        let (coordinator, _, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true
        )

        coordinator.captureSelection()
        try await waitUntil { !outcomes.all.isEmpty }

        #expect(outcomes.all == [.captureFailed])
    }

    @Test func richSourceDuplicateCapturesStillCollapse() async throws {
        var clock = Date(timeIntervalSince1970: 1_753_000_000)
        let reader = FakeReader(result: nil)
        let capture = FakeCapture(result: .copied("same rich text"))
        let (coordinator, store, outcomes) = makeCoordinator(
            reader: reader, capture: capture, prefersRichSource: true, now: { clock }
        )

        coordinator.captureSelection()
        try await waitUntil { outcomes.all.count == 1 }
        clock += 1
        coordinator.captureSelection()
        try await waitUntil { outcomes.all.count == 2 }

        #expect(store.items.count == 1)
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
        #expect(outcomes.all == [.nothingSelected(anchor: nil)])
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

    @Test func hugeBacktickOpenerDoesNotTrapTheCap() {
        // An opener longer than the whole budget can't be closed within it;
        // the degenerate ellipsis-only note beats a crash.
        let reader = FakeReader(result: String(repeating: "`", count: 30000) + "\ncode")
        let (coordinator, store, _) = makeCoordinator(reader: reader, capture: FakeCapture(result: .failed))

        coordinator.captureSelection()

        #expect(store.items.map(\.text) == ["…"])
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
