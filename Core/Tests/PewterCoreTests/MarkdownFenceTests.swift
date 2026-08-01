@testable import PewterCore
import Testing

struct MarkdownFenceTests {
    @Test func openFenceIsDetected() {
        #expect(MarkdownFence.openDelimiter(in: "```\ncode") == "```")
        #expect(MarkdownFence.openDelimiter(in: "````\ncode") == "````")
    }

    @Test func closedFenceIsNotOpen() {
        #expect(MarkdownFence.openDelimiter(in: "```\ncode\n```") == nil)
        #expect(MarkdownFence.openDelimiter(in: "text only") == nil)
    }

    @Test func indentedFenceLinesCountUpToThreeSpaces() {
        #expect(MarkdownFence.openDelimiter(in: "```\ncode\n   ```") == nil)
        // Four spaces of indent makes the backtick run content, per
        // CommonMark, so the fence stays open.
        #expect(MarkdownFence.openDelimiter(in: "```\ncode\n    ```") == "```")
    }

    @Test func shorterBacktickRunsInsideAreContent() {
        #expect(MarkdownFence.openDelimiter(in: "````\n```\ncode") == "````")
        #expect(MarkdownFence.openDelimiter(in: "````\n```\n````") == nil)
    }

    @Test func delimiterOutrunsTheLongestBacktickRun() {
        #expect(MarkdownFence.delimiter(enclosing: ["code"]) == "```")
        #expect(MarkdownFence.delimiter(enclosing: []) == "```")
        #expect(MarkdownFence.delimiter(enclosing: ["a ```` b"]) == "`````")
    }
}
