import Foundation
import PewterCore
import Testing

struct DiagnosticsReportTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func emptyWindowSaysSo() {
        let report = DiagnosticsReport.render(
            entries: [],
            header: "Pewter 1.0 (1) — macOS 15.0",
            generatedAt: Date(timeIntervalSince1970: 1000),
            timeZone: utc
        )
        #expect(report == """
        Pewter 1.0 (1) — macOS 15.0
        Log window: last 10 minutes, generated 1970-01-01 00:16:40 +0000

        No log entries in the window.
        """)
    }

    @Test func entriesRenderAsAlignedColumns() {
        let report = DiagnosticsReport.render(
            entries: [
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 600.25),
                    category: "capture",
                    level: "info",
                    message: "skipping html flavor: 2000000 bytes over the conversion ceiling"
                ),
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 601),
                    category: "storage",
                    level: "error",
                    message: "save failed"
                ),
            ],
            header: "header",
            generatedAt: Date(timeIntervalSince1970: 1000),
            timeZone: utc
        )
        #expect(report == """
        header
        Log window: last 10 minutes, generated 1970-01-01 00:16:40 +0000

        00:10:00.250 info   capture  skipping html flavor: 2000000 bytes over the conversion ceiling
        00:10:01.000 error  storage  save failed
        """)
    }

    @Test func entriesSortByDate() {
        let report = DiagnosticsReport.render(
            entries: [
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 2),
                    category: "panel",
                    level: "info",
                    message: "second"
                ),
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 1),
                    category: "panel",
                    level: "info",
                    message: "first"
                ),
            ],
            header: "",
            generatedAt: Date(timeIntervalSince1970: 3),
            timeZone: utc
        )
        let messages = report.split(separator: "\n").suffix(2).map { $0.suffix(6).trimmingCharacters(in: .whitespaces) }
        #expect(messages == ["first", "second"])
    }

    /// Regression check on output shape — Swift's current sort is stable,
    /// so this can't distinguish the index tie-break from luck; the
    /// tie-break's rationale lives in the implementation comment.
    @Test func equalDatesRenderInInputOrder() {
        let date = Date(timeIntervalSince1970: 5)
        let entries = (1 ... 8).map {
            DiagnosticsEntry(date: date, category: "panel", level: "info", message: "entry \($0)")
        }
        let report = DiagnosticsReport.render(entries: entries, header: "", generatedAt: date, timeZone: utc)
        let messages = report.split(separator: "\n").compactMap { line in
            line.range(of: "entry ").map { String(line[$0.lowerBound...]) }
        }
        #expect(messages == (1 ... 8).map { "entry \($0)" })
    }

    @Test func trailingNewlineDoesNotEmitABlankContinuation() {
        let report = DiagnosticsReport.render(
            entries: [
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 0),
                    category: "panel",
                    level: "info",
                    message: "line\n"
                ),
            ],
            header: "",
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: utc
        )
        #expect(report.hasSuffix("panel    line"))
    }

    @Test func multiLineMessagesIndentContinuations() {
        let report = DiagnosticsReport.render(
            entries: [
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 0),
                    category: "capture",
                    level: "info",
                    message: "first line\nsecond line"
                ),
            ],
            header: "",
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: utc
        )
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        let first = "00:00:00.000 info   capture  first line"
        #expect(lines.contains(Substring(first)))
        let indent = String(repeating: " ", count: first.count - "first line".count)
        #expect(lines.contains(Substring(indent + "second line")))
    }

    @Test func failureRendersReasonUnderTheSameHeader() {
        let report = DiagnosticsReport.failure(
            header: "Pewter 1.0 (1) — macOS 15.0",
            reason: "OSLogStore init denied",
            generatedAt: Date(timeIntervalSince1970: 1000),
            timeZone: utc
        )
        #expect(report == """
        Pewter 1.0 (1) — macOS 15.0
        Log window: last 10 minutes, generated 1970-01-01 00:16:40 +0000

        Diagnostics export failed: OSLogStore init denied
        """)
    }

    @Test func homeDirectoryPathsAreRedacted() {
        let report = DiagnosticsReport.render(
            entries: [
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 0),
                    category: "storage",
                    level: "error",
                    message: "failed to save notes file: /Users/test/Library/Application Support/Pewter/notes.md is locked"
                ),
            ],
            header: "",
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: utc,
            homeDirectory: "/Users/test"
        )
        #expect(report.contains("~/Library/Application Support/Pewter/notes.md"))
        #expect(!report.contains("/Users/test"))
    }

    @Test func failureReasonsAreRedactedToo() {
        let report = DiagnosticsReport.failure(
            header: "",
            reason: "file /Users/test/notes.md unreadable",
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: utc,
            homeDirectory: "/Users/test"
        )
        #expect(report.contains("file ~/notes.md unreadable"))
    }

    @Test func wideLevelAndCategoryStillGetOneSpace() {
        let report = DiagnosticsReport.render(
            entries: [
                DiagnosticsEntry(
                    date: Date(timeIntervalSince1970: 0),
                    category: "categorized",
                    level: "notice",
                    message: "msg"
                ),
            ],
            header: "",
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: utc
        )
        #expect(report.hasSuffix("00:00:00.000 notice categorized msg"))
    }
}
