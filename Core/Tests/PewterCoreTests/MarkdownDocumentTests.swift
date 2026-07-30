import Foundation
@testable import PewterCore
import Testing

struct MarkdownDocumentTests {
    @Test func roundTripsItemsWithMetadata() throws {
        let id = UUID()
        let created = try #require(MarkdownDocument.parseDate("2026-07-29T14:03:22Z"))
        var document = MarkdownDocument()
        document.append(Item(id: id, text: "Ask about retry logic", done: false, createdAt: created))

        let reparsed = MarkdownDocument.parse(document.serialized())
        #expect(reparsed == document)
        #expect(reparsed.items[0].id == id)
        #expect(reparsed.items[0].createdAt == created)
    }

    @Test func adoptsHandWrittenTaskLines() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let document = MarkdownDocument.parse("- [ ] added by hand in vim\n- [x] also done by hand\n", now: now)

        #expect(document.items.count == 2)
        #expect(document.items[0].text == "added by hand in vim")
        #expect(document.items[0].done == false)
        #expect(document.items[0].createdAt == now)
        #expect(document.items[1].done == true)
    }

    @Test func preservesNonTaskLinesVerbatim() {
        let source = """
        ## Research

        - [ ] a task
        some stray prose
        """
        let document = MarkdownDocument.parse(source)

        #expect(document.lines.count == 4)
        #expect(document.lines[0] == .verbatim("## Research"))
        #expect(document.lines[1] == .verbatim(""))
        #expect(document.lines[3] == .verbatim("some stray prose"))

        // Non-task lines survive byte-for-byte; the adopted task line gains
        // its identity comment.
        let serialized = document.serialized()
        #expect(serialized.hasPrefix("## Research\n\n- [ ] a task <!--sl id="))
        #expect(serialized.hasSuffix("-->\nsome stray prose\n"))
    }

    @Test func multilineItemsRoundTrip() {
        var document = MarkdownDocument()
        document.append(Item(text: "first line\nsecond line\nthird line"))

        let serialized = document.serialized()
        #expect(serialized.contains("\n  second line\n  third line"))

        let reparsed = MarkdownDocument.parse(serialized)
        #expect(reparsed.items[0].text == "first line\nsecond line\nthird line")
    }

    @Test func mutationsPreservePosition() {
        let source = """
        ## Heading
        - [ ] first
        - [ ] second
        """
        var document = MarkdownDocument.parse(source)
        var first = document.items[0]
        first.done = true
        document.update(first)

        #expect(document.serialized().contains("- [x] first"))
        #expect(document.lines.count == 3)

        document.remove(id: document.items[1].id)
        #expect(document.items.count == 1)
        #expect(document.lines.count == 2)
    }

    @Test func malformedMetadataGetsFreshIdentity() {
        let document = MarkdownDocument.parse("- [ ] text <!--sl id=not-a-uuid created=whenever-->\n")
        #expect(document.items.count == 1)
        // Unparseable metadata is treated as plain text; the item still loads.
        #expect(!document.items[0].text.isEmpty)
    }

    @Test func emptyDocumentSerializesToEmptyString() {
        #expect(MarkdownDocument().serialized() == "")
        #expect(MarkdownDocument.parse("").items.isEmpty)
    }

    @Test func crlfLineEndingsParse() {
        let document = MarkdownDocument.parse("- [ ] a\r\n- [x] b\r\n")
        #expect(document.items.map(\.text) == ["a", "b"])
        #expect(document.items.map(\.done) == [false, true])
    }

    @Test func uppercaseCheckboxCountsAsDone() {
        let document = MarkdownDocument.parse("- [X] shouty done\n")
        #expect(document.items.first?.done == true)
    }

    @Test func duplicatedMetadataGetsFreshIdentity() {
        let line = "- [ ] pasted twice <!--sl id=8f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8 created=2026-07-29T14:03:22Z-->"
        let document = MarkdownDocument.parse(line + "\n" + line + "\n")

        #expect(document.items.count == 2)
        #expect(document.items[0].id != document.items[1].id)
        #expect(document.items[0].id.uuidString.lowercased() == "8f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8")
    }

    @Test func emptyTaskLineIsPreservedButNotAnItem() {
        let document = MarkdownDocument.parse("- [ ] \n- [ ] real\n")
        #expect(document.items.map(\.text) == ["real"])
        #expect(document.serialized().hasPrefix("- [ ] \n"))
    }

    @Test(arguments: ["\r\n", "\r", "\u{0B}", "\u{2028}"])
    func exoticLineBreaksInItemTextRoundTripSafely(separator: String) {
        // Word/Excel emit U+000B, Cocoa text views U+2028, Windows text \r\n.
        // All must normalize to \n or the serializer writes them into the
        // middle of a task line and the file corrupts on reload.
        let item = Item(text: "alpha\(separator)beta")
        #expect(item.text == "alpha\nbeta")

        var document = MarkdownDocument()
        document.append(item)
        let reparsed = MarkdownDocument.parse(document.serialized())
        #expect(reparsed.items.map(\.text) == ["alpha\nbeta"])
        #expect(reparsed.items.first?.id == item.id)
    }

    @Test func interiorBlankLinesRoundTripWithoutTrailingWhitespace() {
        var document = MarkdownDocument()
        document.append(Item(text: "para one\n\npara two"))

        let serialized = document.serialized()
        // No line may carry trailing whitespace — external editors strip it.
        for line in serialized.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(!line.hasSuffix(" "))
        }

        let reparsed = MarkdownDocument.parse(serialized)
        #expect(reparsed.items.map(\.text) == ["para one\n\npara two"])
    }

    @Test func blankLineBetweenItemAndProseStaysDocumentLevel() {
        let source = "- [ ] task\n\nsome prose\n"
        let document = MarkdownDocument.parse(source)
        #expect(document.items.map(\.text) == ["task"])
        #expect(document.serialized().hasSuffix("\n\nsome prose\n"))
    }

    @Test func tabIndentedLinesAreNotContinuations() {
        // Only two-space indentation continues an item; tab-indented lines
        // (external editors' default) stay document-level verbatim. Pinned
        // as a deliberate format decision.
        let document = MarkdownDocument.parse("- [ ] task\n\ttabbed line\n")
        #expect(document.items.map(\.text) == ["task"])
        #expect(document.lines.count == 2)
        #expect(document.serialized().contains("\ttabbed line"))
    }

    @Test func validIdWithGarbageDateKeepsIdResetsDate() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let document = MarkdownDocument.parse(
            "- [ ] text <!--sl id=8f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8 created=whenever-->\n",
            now: now
        )
        #expect(document.items[0].id.uuidString.lowercased() == "8f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8")
        #expect(document.items[0].createdAt == now)
    }
}
