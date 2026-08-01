import Foundation
@testable import PewterCore
import Testing

struct MarkdownWriterTests {
    @Test func plainParagraphPassesThroughUnescaped() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("2 * 3 = 6, file_name.txt, `already ticked`")]),
        ])
        #expect(markdown == "2 * 3 = 6, file_name.txt, `already ticked`")
    }

    @Test func inlineStylesMark() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([
                RichTextRun("plain "),
                RichTextRun("bold", bold: true),
                RichTextRun(" and "),
                RichTextRun("italic", italic: true),
                RichTextRun(" and "),
                RichTextRun("mono", code: true),
            ]),
        ])
        #expect(markdown == "plain **bold** and *italic* and `mono`")
    }

    @Test func boldItalicNestsWithBoldOutside() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("both", bold: true, italic: true)]),
        ])
        #expect(markdown == "***both***")
    }

    @Test func codeWinsOverBoldAndItalic() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("mono", bold: true, italic: true, code: true)]),
        ])
        #expect(markdown == "`mono`")
    }

    @Test func whitespaceStaysOutsideMarkers() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([
                RichTextRun("a"),
                RichTextRun(" bold ", bold: true),
                RichTextRun("b"),
            ]),
        ])
        #expect(markdown == "a **bold** b")
    }

    @Test func mixedTrailingWhitespaceKeepsItsOrder() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("a \t", bold: true), RichTextRun("b")]),
        ])
        #expect(markdown == "**a** \tb")
    }

    @Test func whitespaceOnlyRunPassesThrough() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([
                RichTextRun("a", bold: true),
                RichTextRun(" ", bold: true),
                RichTextRun("b"),
            ]),
        ])
        #expect(markdown == "**a** b")
    }

    @Test func linkWrapsStyledText() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("Swift", bold: true, link: "https://swift.org")]),
        ])
        #expect(markdown == "[**Swift**](https://swift.org)")
    }

    @Test func headingsClampToThreeAndSuppressBold() {
        let markdown = MarkdownWriter.markdown(from: [
            .heading(level: 1, runs: [RichTextRun("Top", bold: true)]),
            .heading(level: 3, runs: [RichTextRun("Third")]),
            .heading(level: 5, runs: [RichTextRun("Deep")]),
        ])
        #expect(markdown == "# Top\n\n### Third\n\n### Deep")
    }

    @Test func consecutiveListItemsJoinTightly() {
        let markdown = MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("intro")]),
            .listItem(indent: 0, kind: .unordered, runs: [RichTextRun("one")]),
            .listItem(indent: 1, kind: .unordered, runs: [RichTextRun("nested")]),
            .listItem(indent: 0, kind: .unordered, runs: [RichTextRun("two")]),
            .paragraph([RichTextRun("outro")]),
        ])
        #expect(markdown == "intro\n\n- one\n  - nested\n- two\n\noutro")
    }

    @Test func orderedItemsUseTheirNumbers() {
        let markdown = MarkdownWriter.markdown(from: [
            .listItem(indent: 0, kind: .ordered(number: 3), runs: [RichTextRun("three")]),
            .listItem(indent: 0, kind: .ordered(number: 4), runs: [RichTextRun("four")]),
        ])
        #expect(markdown == "3. three\n4. four")
    }

    @Test func nestedItemsIndentToTheParentContentColumn() {
        // "1. " needs 3 columns and "10. " needs 4, or the parent ordered
        // list terminates at the nested bullet.
        let markdown = MarkdownWriter.markdown(from: [
            .listItem(indent: 0, kind: .ordered(number: 1), runs: [RichTextRun("a")]),
            .listItem(indent: 1, kind: .unordered, runs: [RichTextRun("b")]),
            .listItem(indent: 0, kind: .ordered(number: 10), runs: [RichTextRun("ten")]),
            .listItem(indent: 1, kind: .unordered, runs: [RichTextRun("sub")]),
        ])
        #expect(markdown == "1. a\n   - b\n10. ten\n    - sub")
    }

    @Test func codeBlockFencesLines() {
        let markdown = MarkdownWriter.markdown(from: [
            .codeBlock(["let a = 1", "", "print(a)"]),
        ])
        #expect(markdown == "```\nlet a = 1\n\nprint(a)\n```")
    }

    @Test func fenceOutgrowsBackticksInTheContent() {
        let markdown = MarkdownWriter.markdown(from: [
            .codeBlock(["```", "nested fence"]),
        ])
        #expect(markdown == "````\n```\nnested fence\n````")
    }

    @Test func codeSpansDelimitEmbeddedBackticks() {
        #expect(MarkdownWriter.markdown(from: [.paragraph([RichTextRun("a`b", code: true)])])
            == "``a`b``")
        #expect(MarkdownWriter.markdown(from: [.paragraph([RichTextRun("`lead", code: true)])])
            == "`` `lead ``")
    }

    @Test func linkDestinationsAreMadeSafe() {
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "https://a.com/b c(d")]),
        ]) == "[x](<https://a.com/b c(d>)")
        // A destination Markdown can't represent drops the link, not the text.
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "https://a.com/<odd>")]),
        ]) == "x")
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("see [1]", link: "https://a.com")]),
        ]) == "[see \\[1\\]](https://a.com)")
    }

    @Test func executableLinkSchemesAreDropped() {
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "javascript:alert(1)")]),
        ]) == "x")
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "data:text/html;base64,AAAA")]),
        ]) == "x")
        // Safe schemes and scheme-less relative destinations keep the link.
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "mailto:a@b.example")]),
        ]) == "[x](mailto:a@b.example)")
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "docs/readme.md")]),
        ]) == "[x](docs/readme.md)")
        // A colon in the path is not a scheme.
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", link: "https://a.example/a:b")]),
        ]) == "[x](https://a.example/a:b)")
    }

    @Test func emptyLinkMeansNoLink() {
        #expect(MarkdownWriter.markdown(from: [.paragraph([RichTextRun("x", link: "")])]) == "x")
    }

    @Test func strikethroughRunsWrapInTildes() {
        #expect(MarkdownWriter.markdown(from: [.paragraph([RichTextRun("gone", strikethrough: true)])])
            == "~~gone~~")
        #expect(MarkdownWriter.markdown(from: [
            .paragraph([RichTextRun("x", code: true, strikethrough: true)]),
        ]) == "~~`x`~~")
    }

    @Test func quotePrefixes() {
        let markdown = MarkdownWriter.markdown(from: [
            .quote([RichTextRun("wise words")]),
        ])
        #expect(markdown == "> wise words")
    }

    @Test func emptyBlocksProduceEmptyString() {
        #expect(MarkdownWriter.markdown(from: []) == "")
    }
}
