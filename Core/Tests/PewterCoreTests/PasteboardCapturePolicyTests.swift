import Foundation
import PewterCore
import Testing

struct PasteboardCapturePolicyTests {
    struct CapturedCase: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String?
        let expected: PasteboardCaptureResult
        var testDescription: String {
            name
        }
    }

    static let capturedTable: [CapturedCase] = [
        CapturedCase(
            name: "text is a capture",
            text: "hello",
            expected: .copied("hello")
        ),
        CapturedCase(
            name: "whitespace-only text is still a capture — normalization is the store's job",
            text: "  \n",
            expected: .copied("  \n")
        ),
        CapturedCase(
            name: "an empty string is not a capture",
            text: "",
            expected: .nothingSelected
        ),
        CapturedCase(
            name: "no string at all is not a capture",
            text: nil,
            expected: .nothingSelected
        ),
    ]

    @Test(arguments: capturedTable)
    func capturedResult(_ c: CapturedCase) {
        #expect(PasteboardCapturePolicy.capturedResult(from: c.text) == c.expected)
    }

    struct RestoreCase: Sendable, CustomTestStringConvertible {
        let name: String
        let snapshotIsEmpty: Bool
        let changeCount: Int
        let expectedChangeCount: Int
        let verdict: PasteboardCapturePolicy.RestoreDecision
        var testDescription: String {
            name
        }
    }

    static let restoreTable: [RestoreCase] = [
        RestoreCase(
            name: "matching count with a snapshot restores",
            snapshotIsEmpty: false, changeCount: 5, expectedChangeCount: 5,
            verdict: .restore
        ),
        RestoreCase(
            name: "empty snapshot skips even when the count matches",
            snapshotIsEmpty: true, changeCount: 5, expectedChangeCount: 5,
            verdict: .skipEmptySnapshot
        ),
        RestoreCase(
            name: "a foreign write since the copy skips the restore",
            snapshotIsEmpty: false, changeCount: 6, expectedChangeCount: 5,
            verdict: .skipClipboardMoved
        ),
        RestoreCase(
            name: "any mismatch skips, not just a higher count",
            snapshotIsEmpty: false, changeCount: 4, expectedChangeCount: 5,
            verdict: .skipClipboardMoved
        ),
        RestoreCase(
            name: "empty snapshot takes precedence over a moved clipboard",
            snapshotIsEmpty: true, changeCount: 6, expectedChangeCount: 5,
            verdict: .skipEmptySnapshot
        ),
    ]

    @Test(arguments: restoreTable)
    func restoreDecision(_ c: RestoreCase) {
        #expect(PasteboardCapturePolicy.restoreDecision(
            snapshotIsEmpty: c.snapshotIsEmpty,
            changeCount: c.changeCount,
            expectedChangeCount: c.expectedChangeCount
        ) == c.verdict)
    }
}
