import Foundation
@testable import SmartListCore
import Testing

@Test func newItemDefaultsToNotDone() {
    let item = Item(text: "capture me")
    #expect(item.done == false)
    #expect(item.text == "capture me")
}
