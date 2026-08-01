import Foundation

/// Serializes `RichTextBlock`s to Markdown.
///
/// Deliberately conservative: a run only gets markers when its flags say so,
/// and plain text is emitted verbatim with no escaping of incidental `*`,
/// `_`, or backtick characters — ordinary text must survive capture
/// unchanged. The exceptions are the slots where an unescaped character
/// breaks the syntax outright rather than reading oddly: code delimiters,
/// fences, and link labels/destinations.
public enum MarkdownWriter {
    public static func markdown(from blocks: [RichTextBlock]) -> String {
        var pieces: [(text: String, isListItem: Bool)] = []
        // Content column per nesting depth: a nested item must indent to
        // its parent's content column ("1. " needs 3, "10. " needs 4) or
        // the parent list terminates and a new one starts.
        var contentColumns: [Int] = []

        for block in blocks {
            switch block {
            case let .paragraph(runs):
                pieces.append((inline(runs), false))
            case let .heading(level, runs):
                let hashes = String(repeating: "#", count: min(max(level, 1), 3))
                // Headings are already emphasized; bold markers inside one
                // are noise.
                pieces.append((hashes + " " + inline(runs, suppressBold: true), false))
            case let .listItem(indent, kind, runs):
                let depth = max(indent, 0)
                let lead = depth == 0
                    ? 0
                    : (depth - 1 < contentColumns.count ? contentColumns[depth - 1] : depth * 2)
                let marker = switch kind {
                case .unordered: "- "
                case let .ordered(number): "\(number). "
                }
                if contentColumns.count > depth {
                    contentColumns.removeSubrange(depth...)
                }
                // Back-fill skipped depths with the same ladder the lead
                // fallback uses, or the next sibling at this depth would
                // read a narrower column and outdent past its brother.
                while contentColumns.count < depth {
                    contentColumns.append((contentColumns.last ?? 0) + 2)
                }
                contentColumns.append(lead + marker.count)
                pieces.append((String(repeating: " ", count: lead) + marker + inline(runs), true))
            case let .codeBlock(lines):
                pieces.append((fenced(lines), false))
            case let .quote(runs):
                pieces.append(("> " + inline(runs), false))
            }
        }

        // Blank line between blocks, except consecutive list items, which
        // join tightly so a list reads as one list.
        var result = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                result += (piece.isListItem && pieces[index - 1].isListItem) ? "\n" : "\n\n"
            }
            result += piece.text
        }
        return result
    }

    // MARK: - Inline runs

    private static func inline(_ runs: [RichTextRun], suppressBold: Bool = false) -> String {
        var result = ""
        for run in runs {
            guard !run.text.isEmpty else { continue }

            // Whitespace stays outside the markers — wrapping it produces
            // malformed Markdown like "word **". The trailing slice is
            // taken as a suffix so mixed whitespace keeps its order.
            let leading = run.text.prefix { $0 == " " || $0 == "\t" }
            let trailingCount = run.text.reversed().prefix { $0 == " " || $0 == "\t" }.count
            let trailing = run.text.suffix(trailingCount)
            let core = String(run.text.dropFirst(leading.count).dropLast(trailingCount))
            guard !core.isEmpty, !core.allSatisfy(\.isWhitespace) else {
                result += run.text
                continue
            }

            var marked = core
            if run.code {
                marked = codeSpan(core)
            } else {
                if run.italic {
                    marked = "*\(marked)*"
                }
                if run.bold, !suppressBold {
                    marked = "**\(marked)**"
                }
            }
            if let link = run.link {
                marked = linked(marked, to: link)
            }

            result += String(leading) + marked + String(trailing)
        }
        return result
    }

    /// Delimits with one more backtick than the content's longest run, with
    /// the padding spaces Markdown requires when the content starts or ends
    /// with a backtick.
    private static func codeSpan(_ text: String) -> String {
        let ticks = String(repeating: "`", count: longestBacktickRun(in: text) + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return ticks + pad + text + pad + ticks
    }

    /// Captured links render clickable in the panel and in external
    /// editors; anything outside this list (javascript:, data:, …) drops
    /// the link and keeps the text.
    private static let safeSchemes: Set<String> = ["http", "https", "mailto"]

    /// A `]` in the label or whitespace/unbalanced parens in the
    /// destination would end the link early; a destination Markdown can't
    /// represent at all — or shouldn't carry — drops the link and keeps
    /// the text.
    private static func linked(_ label: String, to destination: String) -> String {
        if destination.contains("<") || destination.contains(">")
            || destination.contains(where: \.isNewline)
        {
            return label
        }
        if let colon = destination.firstIndex(of: ":"),
           !destination[..<colon].contains("/")
        {
            let scheme = String(destination[..<colon]).lowercased()
            let isSchemeToken = scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
            if isSchemeToken, !safeSchemes.contains(scheme) {
                return label
            }
        }
        let escaped = label
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        if destination.contains(where: \.isWhitespace) || !parensBalanced(destination) {
            return "[\(escaped)](<\(destination)>)"
        }
        return "[\(escaped)](\(destination))"
    }

    private static func parensBalanced(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 {
                    return false
                }
            }
        }
        return depth == 0
    }

    // MARK: - Code fences

    /// The fence must be longer than any backtick run inside, or the block
    /// closes early and the rest reads as note Markdown.
    private static func fenced(_ lines: [String]) -> String {
        let longest = lines.map(longestBacktickRun).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return ([fence] + lines + [fence]).joined(separator: "\n")
    }

    private static func longestBacktickRun(in text: String) -> Int {
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
