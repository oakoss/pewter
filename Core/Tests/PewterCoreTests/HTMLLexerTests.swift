@testable import PewterCore
import Testing

struct HTMLLexerTests {
    // MARK: - Entities

    @Test func namedEntitiesDecode() {
        #expect(HTMLLexer.decodeEntities("a &amp; b &lt;c&gt; &nbsp;&mdash;") == "a & b <c>  —")
    }

    @Test func numericEntitiesDecode() {
        #expect(HTMLLexer.decodeEntities("&#65;&#x42;&#X43;") == "ABC")
        #expect(HTMLLexer.decodeEntities("&#128512;") == "😀")
    }

    @Test func controlCharacterEntitiesAreRejected() {
        #expect(HTMLLexer.decodeEntities("a&#0;b") == "a&#0;b")
        #expect(HTMLLexer.decodeEntities("a&#8;b") == "a&#8;b")
        // Tab and newline are legitimate whitespace, not injection.
        #expect(HTMLLexer.decodeEntities("a&#9;b") == "a\tb")
        #expect(HTMLLexer.decodeEntities("a&#10;b") == "a\nb")
    }

    @Test func malformedEntitiesStayLiteral() {
        #expect(HTMLLexer.decodeEntities("AT&T") == "AT&T")
        #expect(HTMLLexer.decodeEntities("&unknown;") == "&unknown;")
        #expect(HTMLLexer.decodeEntities("&amp") == "&amp")
        #expect(HTMLLexer.decodeEntities("trailing &") == "trailing &")
        // The semicolon search window is bounded; an over-long name is text.
        #expect(HTMLLexer.decodeEntities("&notarealentity;") == "&notarealentity;")
    }

    @Test func invalidScalarEntitiesStayLiteral() {
        #expect(HTMLLexer.decodeEntities("&#x110000;") == "&#x110000;")
        #expect(HTMLLexer.decodeEntities("&#xD800;") == "&#xD800;")
    }

    // MARK: - Attributes

    @Test func attributeValuesParseInEveryQuotingStyle() {
        #expect(HTMLLexer.attribute("href", in: #" href="https://a.example""#) == "https://a.example")
        #expect(HTMLLexer.attribute("href", in: " href='x'") == "x")
        #expect(HTMLLexer.attribute("href", in: " href=x") == "x")
    }

    @Test func attributeNamesMatchCaseInsensitively() {
        #expect(HTMLLexer.attribute("href", in: #" HREF="x""#) == "x")
    }

    @Test func attributeValuesDecodeEntities() {
        #expect(HTMLLexer.attribute("href", in: #" href="a&amp;b""#) == "a&b")
    }

    @Test func attributeNameInsideAnotherValueDoesNotMatch() {
        #expect(HTMLLexer.attribute("href", in: #" title="use href=here" id="x""#) == nil)
    }

    @Test func missingAttributeIsNil() {
        #expect(HTMLLexer.attribute("href", in: #" class="a""#) == nil)
        #expect(HTMLLexer.attribute("href", in: "") == nil)
    }

    @Test func valuelessAttributeIsEmpty() {
        #expect(HTMLLexer.attribute("checked", in: " checked") == "")
    }

    // MARK: - Style values

    @Test func styleValuesParseAcrossDeclarations() {
        let style = "color: red; font-weight : bold ;font-style:italic"
        #expect(HTMLLexer.styleValue("font-weight", in: style) == "bold")
        #expect(HTMLLexer.styleValue("font-style", in: style) == "italic")
        #expect(HTMLLexer.styleValue("font-family", in: style) == nil)
    }

    // MARK: - Whitespace

    @Test func whitespaceRunsCollapseToOneSpace() {
        #expect(HTMLLexer.collapseWhitespace("a  b\n\tc") == "a b c")
        #expect(HTMLLexer.collapseWhitespace("  a  ") == " a ")
        #expect(HTMLLexer.collapseWhitespace("abc") == "abc")
    }
}
