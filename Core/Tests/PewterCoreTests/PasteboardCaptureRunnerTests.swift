import Foundation
import PewterCore
import Testing

/// Scripted surface: poll results are consumed in order, and
/// `changeCountAfterPolls` models a foreign or late write landing once the
/// poll window is exhausted. Every call is appended to `events` so tests
/// can pin the sequencing — the bracketing and read-before-restore orders
/// are the invariants this seam exists to protect.
@MainActor
private final class SurfaceFake: PasteboardCaptureSurface {
    struct SnapshotToken {}

    var changeCount = 10
    var text: String?
    var hasRestorableContent = true
    var hidCopySucceeds = true
    var pidCopySucceeds = true
    var frontmostAppPid: pid_t?
    var frontmostAppBundleID: String?
    var pollResults: [Int?] = []
    var recentChangeValue = false
    var changeCountAfterPolls: Int?

    private(set) var events: [String] = []

    var restored: Bool {
        events.contains("restore")
    }

    var recentChangeAsked: Bool {
        events.contains("recent")
    }

    func pasteboardFlavors() -> PasteboardFlavors {
        events.append("flavors")
        let text = text
        return PasteboardFlavors(plain: text)
    }

    func rtfBlocks(_ data: Data) -> [RichTextBlock]? {
        nil
    }

    func saveClipboard() -> SnapshotToken? {
        events.append("save")
        return hasRestorableContent ? SnapshotToken() : nil
    }

    func restoreClipboard(_ snapshot: SnapshotToken) {
        events.append("restore")
        changeCount += 1
    }

    func awaitSynthesisReady() async {
        events.append("ready")
    }

    func synthesizeCopy(to pid: pid_t?) async -> Bool {
        events.append(pid.map { "post(\($0))" } ?? "post(hid)")
        return pid == nil ? hidCopySucceeds : pidCopySucceeds
    }

    func pollForChange(from baseline: Int) async -> Int? {
        events.append("poll(\(baseline))")
        let result = pollResults.isEmpty ? nil : pollResults.removeFirst()
        // A successful poll means the live count reached that value.
        if let result {
            changeCount = result
        }
        if pollResults.isEmpty, let after = changeCountAfterPolls {
            changeCount = after
            changeCountAfterPolls = nil
        }
        return result
    }

    func recentClipboardChange() -> Bool {
        events.append("recent")
        return recentChangeValue
    }

    func beginOwnWrites() {
        events.append("begin")
    }

    func endOwnWrites() {
        events.append("end")
    }
}

@MainActor
struct PasteboardCaptureRunnerTests {
    @Test func landedCopyRestoresAndCaptures() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.text = "hello"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("hello"))
        // The full sequence pins every load-bearing order at once:
        // snapshot before the bracket, bracket before synthesis, the text
        // read before the restore, the bracket closed last.
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "flavors", "restore", "end"])
    }

    @Test func trackerIsNeverPolledWhenTheCopyLands() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.text = "hello"
        surface.recentChangeValue = true

        _ = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(!surface.recentChangeAsked)
    }

    @Test func deadHidCopyRetriesViaPid() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil, 11]
        surface.frontmostAppPid = 42
        surface.text = "terminal selection"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("terminal selection"))
        // Both polls compare against the original pre-copy baseline.
        #expect(surface.events == [
            "ready",
            "save",
            "begin",
            "post(hid)",
            "poll(10)",
            "post(42)",
            "poll(10)",
            "flavors",
            "restore",
            "end",
        ])
    }

    @Test func noFrontmostAppSkipsTheRetry() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .nothingSelected)
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "recent", "end"])
    }

    @Test func lateLandingCopyStillRestores() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.changeCountAfterPolls = 12
        surface.text = "late"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("late"))
        #expect(surface.restored)
        #expect(!surface.recentChangeAsked)
    }

    @Test func foreignWriteBetweenCopyAndRestoreIsNotClobbered() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.changeCountAfterPolls = 12
        surface.text = "captured"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("captured"))
        #expect(!surface.restored)
    }

    @Test func emptySnapshotIsNeverRestored() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.hasRestorableContent = false
        surface.text = "captured"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("captured"))
        #expect(!surface.restored)
    }

    @Test func recentAutoCopyIsUsedAndLeftOnTheClipboard() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.recentChangeValue = true
        surface.text = "selected in a TUI"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("selected in a TUI"))
        // The tracker poll precedes the text read: reversed, a write
        // landing between the two would read as recent activity while the
        // captured text predates it.
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "recent", "flavors", "end"])
    }

    @Test func recentChangeWithoutTextIsNotACapture() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.recentChangeValue = true

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .nothingSelected)
        #expect(!surface.restored)
    }

    @Test func staleClipboardTextIsNeverCaptured() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.text = "stale"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .nothingSelected)
        #expect(!surface.restored)
    }

    @Test func hidSynthesisFailureFailsAndClosesTheBracket() async {
        let surface = SurfaceFake()
        surface.hidCopySucceeds = false

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .failed)
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "end"])
    }

    @Test func pidSynthesisFailureFails() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.frontmostAppPid = 42
        surface.pidCopySucceeds = false

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .failed)
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "post(42)", "end"])
    }

    @Test func deadRetryPollStillChecksLateAndRecentPaths() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil, nil]
        surface.frontmostAppPid = 42
        surface.recentChangeValue = true
        surface.text = "auto-copied"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: CopyOnSelectSources())

        #expect(result == .copied("auto-copied"))
        #expect(surface.events == [
            "ready",
            "save",
            "begin",
            "post(hid)",
            "poll(10)",
            "post(42)",
            "poll(10)",
            "recent",
            "flavors",
            "end",
        ])
    }

    @Test func twoAssistSuccessesTeachTheSourcesAndTheThirdCaptureFastPaths() async {
        let sources = CopyOnSelectSources()

        func assistRun(text: String) -> SurfaceFake {
            let surface = SurfaceFake()
            surface.pollResults = [nil, nil]
            surface.frontmostAppPid = 42
            surface.frontmostAppBundleID = "com.example.term"
            surface.recentChangeValue = true
            surface.text = text
            return surface
        }

        let first = assistRun(text: "one")
        #expect(await PasteboardCaptureRunner.run(on: first, sources: sources) == .copied("one"))

        // One success can be a coincidental foreign write; the second
        // capture must still run the full sequence.
        let second = assistRun(text: "two")
        #expect(await PasteboardCaptureRunner.run(on: second, sources: sources) == .copied("two"))
        #expect(second.events.first == "ready")

        let third = SurfaceFake()
        third.frontmostAppBundleID = "com.example.term"
        third.recentChangeValue = true
        third.text = "three"

        let thirdResult = await PasteboardCaptureRunner.run(on: third, sources: sources)

        #expect(thirdResult == .copied("three"))
        // No modifier wait, no synthesis, no poll windows, no clipboard
        // writes — the fast path reads and returns.
        #expect(third.events == ["recent", "flavors"])
    }

    @Test func trustedSourceWithoutRecentActivityRunsTheFullSequence() async {
        let sources = trusted("com.example.term")
        let surface = SurfaceFake()
        surface.frontmostAppBundleID = "com.example.term"
        surface.pollResults = [11]
        surface.text = "hello"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: sources)

        #expect(result == .copied("hello"))
        #expect(surface.events == [
            "recent",
            "ready",
            "save",
            "begin",
            "post(hid)",
            "poll(10)",
            "flavors",
            "restore",
            "end",
        ])
    }

    @Test func trustedSourceWithNonTextClipboardFallsThroughToSynthesis() async {
        let sources = trusted("com.example.term")
        let surface = SurfaceFake()
        surface.frontmostAppBundleID = "com.example.term"
        surface.recentChangeValue = true
        surface.text = nil
        surface.pollResults = [11]

        let result = await PasteboardCaptureRunner.run(on: surface, sources: sources)

        // The fast path read found no text; the full sequence still runs
        // and stays the arbiter of the outcome. The full array pins the
        // load-bearing orders: the tracker consult before any own write,
        // the snapshot after the fast-path read, exactly one consult.
        #expect(result == .nothingSelected)
        #expect(surface.events == [
            "recent", "flavors", "ready", "save", "begin", "post(hid)", "poll(10)", "flavors", "restore", "end",
        ])
    }

    @Test func trustInADifferentAppNeverFastPaths() async {
        let sources = trusted("com.example.other")
        let surface = SurfaceFake()
        surface.frontmostAppBundleID = "com.example.term"
        surface.recentChangeValue = true
        surface.pollResults = [11]
        surface.text = "hello"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: sources)

        // Trust is per-app: another app's learning must not divert this
        // capture from the full sequence, or a foreign clipboard write
        // could be captured as this app's selection.
        #expect(result == .copied("hello"))
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "flavors", "restore", "end"])
    }

    @Test func nilBundleIDNeverFastPathsEvenWithTrustedSources() async {
        let sources = trusted("com.example.term")
        let surface = SurfaceFake()
        surface.frontmostAppBundleID = nil
        surface.recentChangeValue = true
        surface.pollResults = [11]
        surface.text = "hello"

        let result = await PasteboardCaptureRunner.run(on: surface, sources: sources)

        #expect(result == .copied("hello"))
        #expect(surface.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "flavors", "restore", "end"])
    }

    @Test func assistFailureDoesNotTeachTheSources() async {
        let sources = CopyOnSelectSources()
        let first = SurfaceFake()
        first.pollResults = [nil, nil]
        first.frontmostAppPid = 42
        first.frontmostAppBundleID = "com.example.term"
        first.recentChangeValue = true
        first.text = nil

        _ = await PasteboardCaptureRunner.run(on: first, sources: sources)
        #expect(!sources.shouldFastPath("com.example.term"))
    }

    @Test func landedSynthesisResetsTrust() async {
        let sources = trusted("com.example.term")
        let first = SurfaceFake()
        first.frontmostAppBundleID = "com.example.term"
        first.pollResults = [11]
        first.text = "hello"

        _ = await PasteboardCaptureRunner.run(on: first, sources: sources)

        // The landed copy disproved copy-on-select for this app — trusted
        // until contradicted, so the next capture with recent clipboard
        // activity must synthesize instead of fast-pathing stale content.
        #expect(!sources.shouldFastPath("com.example.term"))

        let second = SurfaceFake()
        second.frontmostAppBundleID = "com.example.term"
        second.recentChangeValue = true
        second.pollResults = [11]
        second.text = "fresh"

        let result = await PasteboardCaptureRunner.run(on: second, sources: sources)

        #expect(result == .copied("fresh"))
        #expect(second.events == ["ready", "save", "begin", "post(hid)", "poll(10)", "flavors", "restore", "end"])
    }

    @Test func everyEighthTrustedCaptureReprovesViaTheFullSequence() async {
        let sources = trusted("com.example.term")

        for turn in 1 ... 7 {
            let surface = SurfaceFake()
            surface.frontmostAppBundleID = "com.example.term"
            surface.recentChangeValue = true
            surface.text = "sel \(turn)"
            _ = await PasteboardCaptureRunner.run(on: surface, sources: sources)
            #expect(surface.events == ["recent", "flavors"])
        }

        // The eighth eligible capture declines the fast path so the full
        // sequence can re-prove the classification — the assist re-teaches
        // here; a landed copy would have contradicted instead.
        let eighth = SurfaceFake()
        eighth.frontmostAppBundleID = "com.example.term"
        eighth.recentChangeValue = true
        eighth.pollResults = [nil]
        eighth.text = "sel 8"

        let reproved = await PasteboardCaptureRunner.run(on: eighth, sources: sources)

        #expect(reproved == .copied("sel 8"))
        #expect(eighth.events.first == "ready")

        // Trust survives a passed re-proof: the ninth is fast again.
        let ninth = SurfaceFake()
        ninth.frontmostAppBundleID = "com.example.term"
        ninth.recentChangeValue = true
        ninth.text = "sel 9"

        _ = await PasteboardCaptureRunner.run(on: ninth, sources: sources)
        #expect(ninth.events == ["recent", "flavors"])
    }

    @Test func nilKeyIsNeverRecordedOrTrusted() {
        let sources = CopyOnSelectSources()
        sources.recordAssistSuccess(nil)
        sources.recordAssistSuccess(nil)
        #expect(!sources.shouldFastPath(nil))
    }

    private func trusted(_ key: String) -> CopyOnSelectSources {
        let sources = CopyOnSelectSources()
        sources.recordAssistSuccess(key)
        sources.recordAssistSuccess(key)
        return sources
    }
}
