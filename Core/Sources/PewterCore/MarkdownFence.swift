import Foundation

/// CommonMark's backtick-fence rules, shared by emission and repair: a
/// fence line may be indented up to three spaces, and a closer must be at
/// least as long as its opener — a shorter backtick run inside the block
/// is content.
enum MarkdownFence {
    /// The delimiter of a fence left open in `text`, nil when every fence
    /// is closed.
    static func openDelimiter(in text: String) -> String? {
        var open = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let body = line.drop(while: { $0 == " " })
            guard line.count - body.count <= 3, body.hasPrefix("```") else { continue }
            let ticks = body.prefix(while: { $0 == "`" }).count
            if open == 0 {
                open = ticks
            } else if ticks >= open {
                open = 0
            }
        }
        return open > 0 ? String(repeating: "`", count: open) : nil
    }

    /// A delimiter longer than any backtick run in `lines`, so the fenced
    /// block can't close early.
    static func delimiter(enclosing lines: [String]) -> String {
        let longest = lines.map(longestBacktickRun).max() ?? 0
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
