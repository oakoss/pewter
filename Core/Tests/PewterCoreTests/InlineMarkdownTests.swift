import Foundation
import PewterCore
import Testing

@MainActor
struct InlineMarkdownTests {
    @Test func plainTextIsOneUnstyledRun() {
        #expect(InlineMarkdown.runs(from: "just text") == [RichTextRun("just text")])
    }

    @Test func inlineStylesMapToRunFlags() {
        let runs = InlineMarkdown.runs(from: "**bold** *italic* `code`")
        #expect(runs.contains(RichTextRun("bold", bold: true)))
        #expect(runs.contains(RichTextRun("italic", italic: true)))
        #expect(runs.contains(RichTextRun("code", code: true)))
    }

    @Test func combinedEmphasisKeepsBothFlags() {
        let runs = InlineMarkdown.runs(from: "***both***")
        #expect(runs.contains(RichTextRun("both", bold: true, italic: true)))
    }

    @Test func strikethroughMapsToItsFlag() {
        let runs = InlineMarkdown.runs(from: "~~gone~~ kept")
        #expect(runs.contains(RichTextRun("gone", strikethrough: true)))
        #expect(runs.contains(RichTextRun(" kept")))
    }

    @Test func safeLinksCarryTheirDestination() {
        let runs = InlineMarkdown.runs(from: "[docs](https://swift.org) and [mail](mailto:a@b.c)")
        #expect(runs.contains(RichTextRun("docs", link: "https://swift.org")))
        #expect(runs.contains(RichTextRun("mail", link: "mailto:a@b.c")))
    }

    @Test func unsafeLinkSchemesRenderAsPlainText() {
        for text in [
            "[x](javascript:alert(1))",
            "[x](file:///etc/passwd)",
            "[x](data:text/html,hi)",
        ] {
            let runs = InlineMarkdown.runs(from: text)
            #expect(runs.allSatisfy { $0.link == nil }, "\(text) must not produce a link")
            #expect(runs.contains { $0.text.contains("x") }, "\(text) must keep the label")
        }
    }

    @Test func whitespaceIsPreserved() {
        #expect(InlineMarkdown.runs(from: "two  spaces") == [RichTextRun("two  spaces")])
    }

    @Test func blockSyntaxStaysLiteral() {
        #expect(InlineMarkdown.runs(from: "## heading") == [RichTextRun("## heading")])
        #expect(InlineMarkdown.runs(from: "- item") == [RichTextRun("- item")])
    }
}

struct LinkPolicyTests {
    @Test func onlySafeSchemesAreAllowed() throws {
        #expect(try LinkPolicy.allows(#require(URL(string: "https://a.example"))))
        #expect(try LinkPolicy.allows(#require(URL(string: "HTTP://a.example"))))
        #expect(try LinkPolicy.allows(#require(URL(string: "mailto:a@b.c"))))
        #expect(try !LinkPolicy.allows(#require(URL(string: "file:///etc/passwd"))))
        #expect(try !LinkPolicy.allows(#require(URL(string: "javascript:alert(1)"))))
        #expect(try !LinkPolicy.allows(#require(URL(string: "relative/path"))))
    }
}
