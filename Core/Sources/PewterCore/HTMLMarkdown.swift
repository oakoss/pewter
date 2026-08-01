import Foundation

/// Converts pasteboard HTML to Markdown via `RichTextBlock` and
/// `MarkdownWriter`. Hand-rolled rather than AppKit's HTML importer so the
/// conversion runs — and is tested — in Core.
///
/// Tolerant by design: unknown tags are transparent, mismatched close tags
/// recover, a `<` that opens no tag is text, and only constructs Markdown
/// can express are marked up. Text that arrives plain comes out plain.
enum HTMLMarkdown {
    struct Conversion: Equatable, Sendable {
        let markdown: String
        /// False when nothing in the source needed Markdown — the caller
        /// can prefer the plain-text flavor, which kept the exact
        /// whitespace the HTML walk collapses.
        let styled: Bool
    }

    /// Size limits live upstream in `RichCapture.byteCeiling`, checked on
    /// the raw flavor bytes before any decode.
    static func convert(fromHTML html: String) -> Conversion? {
        var parser = Parser(html)
        let blocks = parser.run()
        guard !blocks.isEmpty else { return nil }
        let markdown = MarkdownWriter.markdown(from: blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Conversion(markdown: markdown, styled: blocks.requiresMarkdown)
    }

    static func markdown(fromHTML html: String) -> String? {
        convert(fromHTML: html)?.markdown
    }

    /// Pasteboard HTML is almost always UTF-8; WebKit occasionally writes
    /// UTF-16 with a BOM. Two NUL hazards hide here: C-string writers leave
    /// a trailing NUL terminator on valid UTF-8, and BOM-less UTF-16 ASCII
    /// *succeeds* as NUL-riddled UTF-8. Trailing NULs are trimmed; the
    /// UTF-16 re-read happens only when the byte shape agrees (even length,
    /// NULs a large share), so a stray interior NUL can't turn good HTML
    /// into mojibake.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16)
        }
        var trimmed = data
        while trimmed.last == 0 {
            trimmed.removeLast()
        }
        if let utf8 = String(data: trimmed, encoding: .utf8) {
            guard utf8.contains("\0") else { return utf8 }
            let nulCount = data.reduce(into: 0) { count, byte in
                if byte == 0 {
                    count += 1
                }
            }
            if data.count.isMultiple(of: 2), nulCount * 3 > data.count {
                return String(data: data, encoding: .utf16LittleEndian)
            }
            return utf8.replacingOccurrences(of: "\0", with: "")
        }
        return String(data: data, encoding: .utf16)
    }

    // MARK: - Parser

    /// The inline style in force at some point of the walk.
    private struct Style: Equatable {
        var bold = false
        var italic = false
        var code = false
        var strikethrough = false
        var link: String?
    }

    /// What one inline tag asserts. `nil` inherits; an explicit value wins,
    /// so `<b style="font-weight:normal">` (a well-known clipboard wrapper
    /// shape) does NOT bold its subtree.
    private struct Effects {
        var bold: Bool?
        var italic: Bool?
        var code: Bool?
        var strikethrough: Bool?
        var link: String?
    }

    /// An open inline tag remembers the style it replaced, making close —
    /// including a mismatched close popping strays — a constant-time
    /// restore.
    private struct OpenTag {
        let name: String
        let previous: Style
    }

    private struct Parser {
        private let html: String
        private var index: String.Index

        private var blocks: [RichTextBlock] = []
        private var runs: [RichTextRun] = []
        private var stack: [OpenTag] = []
        private var style = Style()
        private var listStack: [(ordered: Bool, counter: Int)] = []
        private var currentItem: (indent: Int, kind: ListKind)?
        private var quoteDepth = 0
        private var headingLevel: Int?
        private var preDepth = 0
        private var preText = ""
        private var skipDepth = 0

        /// Containers whose text content is never note content.
        private static let skippedContainers: Set<String> = ["style", "script", "head", "title"]
        private static let inlineTags: Set<String> = [
            "b", "strong", "i", "em", "code", "tt", "kbd", "samp", "a", "span", "font",
            "s", "del", "strike",
        ]
        /// Tags that end the current block on open and close.
        private static let blockTags: Set<String> = [
            "p", "div", "section", "article", "header", "footer", "main",
            "table", "tr", "td", "th", "figure", "figcaption", "hr",
        ]

        init(_ html: String) {
            self.html = html
            index = html.startIndex
        }

        mutating func run() -> [RichTextBlock] {
            while index < html.endIndex {
                if html[index] == "<" {
                    parseTag()
                } else {
                    parseText()
                }
            }
            flushPre()
            flushRuns()
            return blocks
        }

        // MARK: Text

        private mutating func parseText() {
            let start = index
            while index < html.endIndex, html[index] != "<" {
                index = html.index(after: index)
            }
            let raw = String(html[start ..< index])
            guard skipDepth == 0 else { return }
            let decoded = HTMLLexer.decodeEntities(raw)
            if preDepth > 0 {
                preText += decoded
            } else {
                // Code keeps its whitespace — indentation is content there,
                // and an all-code paragraph becomes a fence line.
                append(style.code ? decoded : HTMLLexer.collapseWhitespace(decoded))
            }
        }

        /// Appends text in the current style, merging into the previous run
        /// when the style matches — split runs would otherwise emit
        /// back-to-back markers like `**foo****bar**`.
        private mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = runs.last,
               last.bold == style.bold, last.italic == style.italic,
               last.code == style.code, last.strikethrough == style.strikethrough,
               last.link == style.link
            {
                runs[runs.count - 1].text += text
            } else {
                runs.append(RichTextRun(
                    text,
                    bold: style.bold,
                    italic: style.italic,
                    code: style.code,
                    strikethrough: style.strikethrough,
                    link: style.link
                ))
            }
        }

        /// Emits already-literal text: no entity decoding, no collapsing.
        private mutating func literal(_ text: String) {
            guard skipDepth == 0 else { return }
            if preDepth > 0 {
                preText += text
            } else {
                append(text)
            }
        }

        // MARK: Tags

        private mutating func parseTag() {
            if html[index...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: index ..< html.endIndex) {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                return
            }

            // A "<" not followed by a tag-ish character is content, not
            // markup — "a < b" and "i < n" must survive capture.
            let afterOpen = html.index(after: index)
            guard afterOpen < html.endIndex else {
                literal("<")
                index = html.endIndex
                return
            }
            let next = html[afterOpen]
            guard next.isLetter || next == "/" || next == "!" || next == "?" else {
                literal("<")
                index = afterOpen
                return
            }

            guard let close = html[index...].firstIndex(of: ">") else {
                index = html.endIndex
                return
            }
            let inner = String(html[afterOpen ..< close])
            index = html.index(after: close)

            if inner.hasPrefix("!") || inner.hasPrefix("?") {
                return
            }

            let isClosing = inner.hasPrefix("/")
            let body = isClosing ? String(inner.dropFirst()) : inner
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard !name.isEmpty else {
                literal("<" + inner + ">")
                return
            }
            let attributes = String(body.dropFirst(name.count))

            if isClosing {
                handleClose(name)
            } else {
                handleOpen(name, attributes: attributes)
            }
        }

        private mutating func handleOpen(_ name: String, attributes: String) {
            if Self.skippedContainers.contains(name) {
                skipDepth += 1
                return
            }
            guard skipDepth == 0 else { return }

            switch name {
            case _ where Self.inlineTags.contains(name):
                stack.append(OpenTag(name: name, previous: style))
                apply(Self.effects(of: name, attributes: attributes))
            case "br":
                if preDepth > 0 {
                    preText += "\n"
                } else {
                    runs.append(RichTextRun("\n"))
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushRuns()
                headingLevel = Int(name.dropFirst())
            case "ul", "ol":
                // Text already collected for an enclosing <li> becomes its
                // item before the nested list's own items start.
                flushRuns()
                if name == "ol" {
                    let start = HTMLLexer.attribute("start", in: attributes).flatMap(Int.init) ?? 1
                    listStack.append((ordered: true, counter: max(1, start) - 1))
                } else {
                    listStack.append((ordered: false, counter: 0))
                }
            case "li":
                flushRuns()
                if listStack.isEmpty {
                    currentItem = (indent: 0, kind: .unordered)
                } else {
                    let top = listStack.count - 1
                    if listStack[top].ordered {
                        listStack[top].counter += 1
                        currentItem = (indent: top, kind: .ordered(number: listStack[top].counter))
                    } else {
                        currentItem = (indent: top, kind: .unordered)
                    }
                }
            case "blockquote":
                flushRuns()
                quoteDepth += 1
            case "pre":
                flushRuns()
                preDepth += 1
            case _ where Self.blockTags.contains(name):
                flushRuns()
            default:
                break
            }
        }

        private mutating func handleClose(_ name: String) {
            if Self.skippedContainers.contains(name) {
                skipDepth = max(0, skipDepth - 1)
                return
            }
            guard skipDepth == 0 else { return }

            switch name {
            case _ where Self.inlineTags.contains(name):
                if let match = stack.lastIndex(where: { $0.name == name }) {
                    style = stack[match].previous
                    stack.removeSubrange(match...)
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushRuns()
                headingLevel = nil
            case "li":
                flushRuns()
                currentItem = nil
            case "ul", "ol":
                flushRuns()
                currentItem = nil
                if !listStack.isEmpty {
                    listStack.removeLast()
                }
            case "blockquote":
                flushRuns()
                quoteDepth = max(0, quoteDepth - 1)
            case "pre":
                flushPre()
                preDepth = max(0, preDepth - 1)
            case _ where Self.blockTags.contains(name):
                flushRuns()
            default:
                break
            }
        }

        private mutating func apply(_ effects: Effects) {
            if let bold = effects.bold {
                style.bold = bold
            }
            if let italic = effects.italic {
                style.italic = italic
            }
            if let code = effects.code {
                style.code = code
            }
            if let strikethrough = effects.strikethrough {
                style.strikethrough = strikethrough
            }
            if let link = effects.link {
                style.link = link
            }
        }

        // MARK: Flushing

        private mutating func flushRuns() {
            // A paragraph that is entirely code is a code line, not a
            // sentence with an inline fragment — emit it fenced, merging
            // into the previous fence so per-line markup (one styled <div>
            // per source line) reads back as one block.
            let hasContent = runs.contains { !$0.text.allSatisfy(\.isWhitespace) }
            // A linked code run must keep its URL, which a fence can't
            // carry — it falls through to the inline path instead.
            let isAllCode = hasContent && runs.allSatisfy {
                ($0.code && $0.link == nil) || $0.text.allSatisfy(\.isWhitespace)
            }
            if isAllCode, headingLevel == nil, currentItem == nil, quoteDepth == 0 {
                defer { runs = [] }
                // Whitespace-only non-code runs are inter-tag formatting,
                // not content; indentation inside a code run is untouched.
                var codeRuns = runs
                while let first = codeRuns.first, !first.code, first.text.allSatisfy(\.isWhitespace) {
                    codeRuns.removeFirst()
                }
                while let last = codeRuns.last, !last.code, last.text.allSatisfy(\.isWhitespace) {
                    codeRuns.removeLast()
                }
                var lines = codeRuns.map(\.text).joined()
                    .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map(String.init)
                while let first = lines.first, first.allSatisfy(\.isWhitespace) {
                    lines.removeFirst()
                }
                while let last = lines.last, last.allSatisfy(\.isWhitespace) {
                    lines.removeLast()
                }
                guard !lines.isEmpty else { return }
                if case let .codeBlock(previous) = blocks.last {
                    blocks[blocks.count - 1] = .codeBlock(previous + lines)
                } else {
                    blocks.append(.codeBlock(lines))
                }
                return
            }

            // Inter-tag whitespace collects at block edges; trim it so
            // formatting-only source whitespace never becomes content.
            while let first = runs.first, first.text.allSatisfy(\.isWhitespace) {
                runs.removeFirst()
            }
            if !runs.isEmpty {
                runs[0].text = String(runs[0].text.drop(while: { $0 == " " || $0 == "\t" }))
            }
            while let last = runs.last, last.text.allSatisfy(\.isWhitespace) {
                runs.removeLast()
            }
            if !runs.isEmpty {
                while runs[runs.count - 1].text.hasSuffix(" ") || runs[runs.count - 1].text.hasSuffix("\t") {
                    runs[runs.count - 1].text.removeLast()
                }
            }
            guard !runs.isEmpty else { return }
            defer { runs = [] }

            if let level = headingLevel {
                blocks.append(.heading(level: level, runs: runs))
            } else if let item = currentItem {
                blocks.append(.listItem(indent: item.indent, kind: item.kind, runs: runs))
            } else if quoteDepth > 0 {
                blocks.append(.quote(runs))
            } else {
                blocks.append(.paragraph(runs))
            }
        }

        private mutating func flushPre() {
            guard !preText.isEmpty else { return }
            var lines = preText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            while lines.first?.isEmpty == true {
                lines.removeFirst()
            }
            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
            if !lines.isEmpty {
                blocks.append(.codeBlock(lines))
            }
            preText = ""
        }

        // MARK: Effects and attributes

        private static func effects(of name: String, attributes: String) -> Effects {
            var effects = Effects()
            switch name {
            case "b", "strong":
                effects.bold = true
            case "i", "em":
                effects.italic = true
            case "code", "tt", "kbd", "samp":
                effects.code = true
            case "s", "del", "strike":
                effects.strikethrough = true
            case "a":
                effects.link = HTMLLexer.attribute("href", in: attributes)
            default:
                break
            }
            guard let styleAttribute = HTMLLexer.attribute("style", in: attributes)?.lowercased() else {
                return effects
            }
            if let weight = HTMLLexer.styleValue("font-weight", in: styleAttribute) {
                if weight == "bold" || weight == "bolder" {
                    effects.bold = true
                } else if weight == "normal" || weight == "lighter" {
                    effects.bold = false
                } else if let value = Int(weight) {
                    effects.bold = value >= 600
                }
            }
            if let slant = HTMLLexer.styleValue("font-style", in: styleAttribute) {
                if slant == "italic" || slant == "oblique" {
                    effects.italic = true
                } else if slant == "normal" {
                    effects.italic = false
                }
            }
            if let family = HTMLLexer.styleValue("font-family", in: styleAttribute),
               RichTextFont.isMonospacedFamily(family)
            {
                effects.code = true
            }
            if let decoration = HTMLLexer.styleValue("text-decoration", in: styleAttribute) {
                if decoration.contains("line-through") {
                    effects.strikethrough = true
                } else if decoration == "none" {
                    effects.strikethrough = false
                }
            }
            return effects
        }
    }
}
