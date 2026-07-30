import Foundation
@testable import SmartListCore
import Testing

struct ItemFormatterTests {
    @Test func listTextOmitsMetadata() {
        let items = [
            Item(text: "first", done: false),
            Item(text: "second", done: true),
        ]
        #expect(ItemFormatter.listText(items) == "- [ ] first\n- [x] second")
    }

    @Test func listTextIndentsMultilineItems() {
        let items = [Item(text: "prompt line one\nprompt line two")]
        #expect(ItemFormatter.listText(items) == "- [ ] prompt line one\n  prompt line two")
    }

    @Test func itemTextIsRawText() {
        let item = Item(text: "**bold** prompt")
        #expect(ItemFormatter.itemText(item) == "**bold** prompt")
    }
}
