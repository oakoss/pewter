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

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("hello"))
        // The full sequence pins every load-bearing order at once:
        // snapshot before the bracket, bracket before synthesis, the text
        // read before the restore, the bracket closed last.
        #expect(surface.events == ["save", "begin", "post(hid)", "poll(10)", "flavors", "restore", "end"])
    }

    @Test func trackerIsNeverPolledWhenTheCopyLands() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.text = "hello"
        surface.recentChangeValue = true

        _ = await PasteboardCaptureRunner.run(on: surface)

        #expect(!surface.recentChangeAsked)
    }

    @Test func deadHidCopyRetriesViaPid() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil, 11]
        surface.frontmostAppPid = 42
        surface.text = "terminal selection"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("terminal selection"))
        // Both polls compare against the original pre-copy baseline.
        #expect(surface.events == [
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

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .nothingSelected)
        #expect(surface.events == ["save", "begin", "post(hid)", "poll(10)", "recent", "end"])
    }

    @Test func lateLandingCopyStillRestores() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.changeCountAfterPolls = 12
        surface.text = "late"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("late"))
        #expect(surface.restored)
        #expect(!surface.recentChangeAsked)
    }

    @Test func foreignWriteBetweenCopyAndRestoreIsNotClobbered() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.changeCountAfterPolls = 12
        surface.text = "captured"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("captured"))
        #expect(!surface.restored)
    }

    @Test func emptySnapshotIsNeverRestored() async {
        let surface = SurfaceFake()
        surface.pollResults = [11]
        surface.hasRestorableContent = false
        surface.text = "captured"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("captured"))
        #expect(!surface.restored)
    }

    @Test func recentAutoCopyIsUsedAndLeftOnTheClipboard() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.recentChangeValue = true
        surface.text = "selected in a TUI"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("selected in a TUI"))
        // The tracker poll precedes the text read: reversed, a write
        // landing between the two would read as recent activity while the
        // captured text predates it.
        #expect(surface.events == ["save", "begin", "post(hid)", "poll(10)", "recent", "flavors", "end"])
    }

    @Test func recentChangeWithoutTextIsNotACapture() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.recentChangeValue = true

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .nothingSelected)
        #expect(!surface.restored)
    }

    @Test func staleClipboardTextIsNeverCaptured() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.text = "stale"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .nothingSelected)
        #expect(!surface.restored)
    }

    @Test func hidSynthesisFailureFailsAndClosesTheBracket() async {
        let surface = SurfaceFake()
        surface.hidCopySucceeds = false

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .failed)
        #expect(surface.events == ["save", "begin", "post(hid)", "end"])
    }

    @Test func pidSynthesisFailureFails() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil]
        surface.frontmostAppPid = 42
        surface.pidCopySucceeds = false

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .failed)
        #expect(surface.events == ["save", "begin", "post(hid)", "poll(10)", "post(42)", "end"])
    }

    @Test func deadRetryPollStillChecksLateAndRecentPaths() async {
        let surface = SurfaceFake()
        surface.pollResults = [nil, nil]
        surface.frontmostAppPid = 42
        surface.recentChangeValue = true
        surface.text = "auto-copied"

        let result = await PasteboardCaptureRunner.run(on: surface)

        #expect(result == .copied("auto-copied"))
        #expect(surface.events == [
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
}
