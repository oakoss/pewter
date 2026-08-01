import Foundation
@testable import PewterCore
import Testing

struct HTMLMarkdownTests {
    @Test func inlineTagsConvert() {
        let html = "<p>plain <b>bold</b> <strong>strong</strong> <i>italic</i> <em>em</em> <code>mono</code></p>"
        #expect(HTMLMarkdown.markdown(fromHTML: html)
            == "plain **bold** **strong** *italic* *em* `mono`")
    }

    @Test func linksConvert() {
        let html = #"<p>see <a href="https://swift.org">Swift</a> docs</p>"#
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "see [Swift](https://swift.org) docs")
    }

    @Test func headingsConvertAndClamp() {
        let html = "<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4>"
        #expect(HTMLMarkdown.markdown(fromHTML: html)
            == "# One\n\n## Two\n\n### Three\n\n### Four")
    }

    @Test func nestedListsConvert() {
        let html = """
        <ul>
          <li>one</li>
          <li>two
            <ul><li>nested</li></ul>
          </li>
          <li>three</li>
        </ul>
        """
        #expect(HTMLMarkdown.markdown(fromHTML: html)
            == "- one\n- two\n  - nested\n- three")
    }

    @Test func orderedListsCountAndHonorStart() {
        let html = #"<ol start="3"><li>three</li><li>four</li></ol>"#
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "3. three\n4. four")
    }

    @Test func preBecomesCodeBlock() {
        let html = "<p>before</p><pre>let a = 1\nprint(a)\n</pre>"
        #expect(HTMLMarkdown.markdown(fromHTML: html)
            == "before\n\n```\nlet a = 1\nprint(a)\n```")
    }

    @Test func preservesIndentationInsidePre() {
        let html = "<pre><code>if x {\n    y()\n}</code></pre>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "```\nif x {\n    y()\n}\n```")
    }

    @Test func blockquoteConverts() {
        let html = "<blockquote><p>wise words</p></blockquote>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "> wise words")
    }

    @Test func entitiesDecode() {
        let html = "<p>a &amp; b &lt;c&gt; &quot;d&quot; &#8212; &#x2713; e&nbsp;f</p>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "a & b <c> \"d\" — ✓ e f")
    }

    @Test func styleAndScriptContentIsDropped() {
        let html = """
        <html><head><title>Page</title><style>p { color: red }</style></head>
        <body><script>alert("hi")</script><p>content</p></body></html>
        """
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "content")
    }

    @Test func styledSpansConvert() {
        let html = #"<span style="font-weight: 700">bold</span> <span style="font-style: italic">it</span> <span style="font-family: Menlo, monospace">mono</span>"#
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "**bold** *it* `mono`")
    }

    @Test func normalWeightSpanStaysPlain() {
        let html = #"<span style="font-weight: 400">regular</span>"#
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "regular")
    }

    @Test func interTagWhitespaceCollapses() {
        let html = "<p>\n  spread\n  across\n  lines\n</p>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "spread across lines")
    }

    @Test func splitStyledRunsMergeIntoOneMarker() {
        let html = "<p><b>fo</b><b>o</b></p>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "**foo**")
    }

    @Test func brBreaksTheLineWithinAParagraph() {
        let html = "<p>first<br>second</p>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "first\nsecond")
    }

    @Test func mismatchedCloseTagsRecover() {
        let html = "<p><b>bold <i>both</b> plain</p>"
        // Closing </b> pops the stray <i> too; "plain" comes out unmarked.
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "**bold** ***both*** plain")
    }

    @Test func unknownTagsAreTransparent() {
        let html = "<article><custom-widget>hello</custom-widget> <wbr>world</article>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "hello world")
    }

    @Test func emptyAndMarkupOnlyInputsReturnNil() {
        #expect(HTMLMarkdown.markdown(fromHTML: "") == nil)
        #expect(HTMLMarkdown.markdown(fromHTML: "<div>\n  \n</div>") == nil)
        #expect(HTMLMarkdown.markdown(fromHTML: "<style>p{}</style>") == nil)
    }

    @Test func browserPasteboardFixtureConverts() {
        // The shape Safari/Chrome put on the pasteboard: meta prelude,
        // styled spans, semantic tags, entity-encoded punctuation.
        let html = """
        <meta charset="UTF-8"><p>The <strong>capture</strong> flow uses \
        <a href="https://developer.apple.com/documentation/appkit/nspasteboard">NSPasteboard</a> \
        &amp; falls back to <code>Cmd+C</code>.</p><ul><li>AX first</li><li>pasteboard second</li></ul>
        """
        #expect(HTMLMarkdown.markdown(fromHTML: html)
            ==
            "The **capture** flow uses [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard) & falls back to `Cmd+C`.\n\n- AX first\n- pasteboard second")
    }

    @Test func plainTextWithoutTagsPassesThrough() {
        #expect(HTMLMarkdown.markdown(fromHTML: "just plain text") == "just plain text")
    }

    @Test func conversionReportsWhetherAnythingWasStyled() throws {
        let styled = try #require(HTMLMarkdown.convert(fromHTML: "<p><b>bold</b></p>"))
        #expect(styled.styled)
        // Structure counts as styled even without inline marks.
        let list = try #require(HTMLMarkdown.convert(fromHTML: "<ul><li>x</li></ul>"))
        #expect(list.styled)
        let plain = try #require(HTMLMarkdown.convert(fromHTML: "<div>one</div><div>two</div>"))
        #expect(!plain.styled)
    }

    @Test func lessThanInTextIsContentNotMarkup() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>if a < b then c > d</p>")
            == "if a < b then c > d")
        #expect(HTMLMarkdown.markdown(fromHTML: "<pre>for (i = 0; i < n; i++) {}</pre>")
            == "```\nfor (i = 0; i < n; i++) {}\n```")
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>5<6</p>") == "5<6")
    }

    @Test func clipboardWrapperBoldWithNormalWeightStaysPlain() {
        let html = #"<b style="font-weight:normal" id="docs-internal-guid-abc"><p>Hello world</p></b>"#
        let conversion = HTMLMarkdown.convert(fromHTML: html)
        #expect(conversion?.markdown == "Hello world")
        #expect(conversion?.styled == false)
    }

    @Test func commonPunctuationEntitiesDecode() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>a&mdash;b&hellip; &lsquo;q&rsquo; &copy;</p>")
            == "a—b… \u{2018}q\u{2019} ©")
    }

    @Test func malformedEntitiesSurviveLiterally() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>&#; &#abc; &; & &&amp;&</p>")
            == "&#; &#abc; &; & &&&")
        // Semicolon beyond the 10-character lookahead: stays literal.
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>&#x0001F600;</p>") == "&#x0001F600;")
        // Surrogate scalar and C0 controls are rejected, not crashed on.
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>&#55296;x</p>") == "&#55296;x")
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>a&#0;b</p>") == "a&#0;b")
    }

    @Test func brInsidePreBreaksTheLine() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<pre>a<br>b</pre>") == "```\na\nb\n```")
    }

    @Test func truncatedHTMLRecovers() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<p><b>bold tail") == "**bold tail**")
        #expect(HTMLMarkdown.markdown(fromHTML: "<pre>code") == "```\ncode\n```")
        // A dangling open bracket at EOF drops; text before it survives.
        #expect(HTMLMarkdown.markdown(fromHTML: "text <b") == "text")
    }

    @Test func structuralMisnestingRecovers() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<ul><li>x<ol><li>y</ul></ol>")
            == "- x\n  1. y")
        #expect(HTMLMarkdown.markdown(fromHTML: "<ul><li>x<pre>y</pre></li></ul>")
            == "- x\n\n```\ny\n```")
    }

    @Test func orderedStartClampsToOne() {
        #expect(HTMLMarkdown.markdown(fromHTML: #"<ol start="0"><li>a</li><li>b</li></ol>"#)
            == "1. a\n2. b")
    }

    @Test func oversizedInputSkipsConversion() {
        let huge = String(repeating: "a", count: HTMLMarkdown.byteCeiling + 1)
        #expect(HTMLMarkdown.convert(fromHTML: huge) == nil)
    }

    @Test func dataDecodingHandlesEncodings() {
        #expect(HTMLMarkdown.decode(Data("<p>utf8</p>".utf8)) == "<p>utf8</p>")

        var utf16 = Data([0xFF, 0xFE])
        for unit in "<p>x</p>".utf16 {
            utf16.append(UInt8(unit & 0xFF))
            utf16.append(UInt8(unit >> 8))
        }
        #expect(HTMLMarkdown.decode(utf16) == "<p>x</p>")

        // BOM-less UTF-16LE ASCII decodes "successfully" as NUL-riddled
        // UTF-8; it must be recognized and re-read, not stored as garbage.
        var bomless = Data()
        for unit in "<p>y</p>".utf16 {
            bomless.append(UInt8(unit & 0xFF))
            bomless.append(UInt8(unit >> 8))
        }
        #expect(HTMLMarkdown.decode(bomless) == "<p>y</p>")
    }

    @Test func monospaceSpanLinesBecomeOneFenceWithIndentation() {
        // The shape browsers serialize for a non-<pre> code selection:
        // one styled <div> per source line, indentation as literal spaces.
        let html = """
        <div><span style="font-family: Menlo, monospace">func main() {</span></div>\
        <div><span style="font-family: Menlo, monospace">    print("hi")</span></div>\
        <div><span style="font-family: Menlo, monospace">}</span></div>
        """
        #expect(HTMLMarkdown.markdown(fromHTML: html)
            == "```\nfunc main() {\n    print(\"hi\")\n}\n```")
    }

    @Test func allCodeParagraphBecomesAFence() {
        #expect(HTMLMarkdown.markdown(fromHTML: "<p><code>npm install</code></p>")
            == "```\nnpm install\n```")
        // A fragment inside a sentence stays inline.
        #expect(HTMLMarkdown.markdown(fromHTML: "<p>run <code>ls</code> now</p>")
            == "run `ls` now")
    }

    @Test func prettyPrintedMonospaceKeepsExactIndentation() {
        // Newline-indented markup between tags is formatting, not content —
        // it must not shift fence lines or add trailing spaces.
        let html = """
        <p class="p1">
        <span style="font-family: 'Menlo'">let x = 1</span>
        </p>
        <p class="p1">
        <span style="font-family: 'Menlo'">    let y = 2</span>
        </p>
        """
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "```\nlet x = 1\n    let y = 2\n```")
    }

    @Test func linkedCodeKeepsItsLink() {
        let html = #"<div><a href="https://a.example"><code>Foo.swift</code></a></div>"#
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "[`Foo.swift`](https://a.example)")
    }

    @Test func skippedListDepthKeepsSiblingsAligned() {
        let html = "<ul><li>a<ul><ul><li>b</li><li>c</li></ul></ul></li></ul>"
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "- a\n    - b\n    - c")
    }

    @Test func attributeLookupIgnoresNamesInsideOtherValues() {
        let html = #"<a title="link href = trap" href="https://real.example">x</a>"#
        #expect(HTMLMarkdown.markdown(fromHTML: html) == "[x](https://real.example)")
    }

    @Test func nulBytesDoNotTurnHTMLIntoMojibake() {
        // A C-string writer's trailing NUL on valid UTF-8.
        #expect(HTMLMarkdown.decode(Data("<p>ab</p>".utf8) + Data([0])) == "<p>ab</p>")
        // A stray interior NUL is stripped, not treated as UTF-16.
        #expect(HTMLMarkdown.decode(Data("<p>a".utf8) + Data([0]) + Data("b</p>".utf8))
            == "<p>ab</p>")
    }

    @Test func convertedMarkdownRoundTripsThroughTheNotesFile() throws {
        let html = """
        <p>intro with <b>bold</b></p><ul><li>one</li><li>two</li></ul>\
        <pre>let a = 1\n\nprint(a)</pre><p>- [ ] looks like a task</p>
        """
        let markdown = try #require(HTMLMarkdown.markdown(fromHTML: html))

        var document = MarkdownDocument()
        document.append(Item(text: markdown))
        let reparsed = MarkdownDocument.parse(document.serialized())

        #expect(reparsed.items.count == 1)
        #expect(reparsed.items.first?.text == Item(text: markdown).text)
    }
}
