import Foundation
@testable import PewterCore
import Testing

struct ItemFormatterTests {
    @Test func numberedListIgnoresDoneState() {
        let items = [
            Item(text: "first", done: false),
            Item(text: "second", done: true),
        ]
        #expect(ItemFormatter.listText(items, style: .numbered) == "1. first\n2. second")
    }

    @Test func numberedListAlignsMultilineContinuations() {
        let items = [Item(text: "prompt line one\nprompt line two")]
        #expect(ItemFormatter.listText(items, style: .numbered) == "1. prompt line one\n   prompt line two")
    }

    @Test func numberedListWidensIndentPastNineItems() {
        let items = (1 ... 9).map { Item(text: "item \($0)") } + [Item(text: "tenth\ncontinued")]
        let lastTwoLines = ItemFormatter.listText(items, style: .numbered)
            .split(separator: "\n")
            .suffix(2)
        #expect(lastTwoLines == ["10. tenth", "    continued"])
    }

    @Test func bulletedListUsesDashesAndTwoSpaceIndent() {
        let items = [
            Item(text: "first\ncontinued"),
            Item(text: "second", done: true),
        ]
        #expect(ItemFormatter.listText(items, style: .bulleted) == "- first\n  continued\n- second")
    }

    @Test func taskListCarriesDoneStateAndTwoSpaceIndent() {
        let items = [
            Item(text: "first\ncontinued"),
            Item(text: "second", done: true),
        ]
        #expect(ItemFormatter.listText(items, style: .taskList) == "- [ ] first\n  continued\n- [x] second")
    }

    @Test func singleItemTextIsRawText() {
        let item = Item(text: "**bold** prompt")
        #expect(ItemFormatter.itemsText([item]) == "**bold** prompt")
    }

    @Test func itemsTextSeparatesWithBlankLines() {
        let items = [
            Item(text: "first"),
            Item(text: "multi\nline"),
            Item(text: "last"),
        ]
        #expect(ItemFormatter.itemsText(items) == "first\n\nmulti\nline\n\nlast")
        #expect(ItemFormatter.itemsText([]) == "")
    }
}
