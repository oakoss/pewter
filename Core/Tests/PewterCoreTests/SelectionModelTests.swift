import Foundation
@testable import PewterCore
import Testing

struct SelectionModelTests {
    let ids = (0 ..< 6).map { _ in UUID() }

    @Test func selectCollapsesToOne() {
        var model = SelectionModel()
        model.select(ids[1])
        model.select(ids[3])
        #expect(model.selected == [ids[3]])
        #expect(model.anchor == ids[3])
        #expect(model.lead == ids[3])
        #expect(model.single == ids[3])
    }

    @Test func toggleAddsAndRemoves() {
        var model = SelectionModel()
        model.select(ids[0])
        model.toggle(ids[2])
        #expect(model.selected == [ids[0], ids[2]])
        #expect(model.anchor == ids[2])
        #expect(model.single == nil)

        model.toggle(ids[2])
        #expect(model.selected == [ids[0]])

        model.toggle(ids[0])
        #expect(model.isEmpty)
        #expect(model.anchor == nil)
        #expect(model.lead == nil)
    }

    @Test func extendSelectsRangeInEitherDirection() {
        var model = SelectionModel()
        model.select(ids[1])
        model.extend(to: ids[4], order: ids)
        #expect(model.selected == Set(ids[1 ... 4]))
        #expect(model.anchor == ids[1])
        #expect(model.lead == ids[4])

        model.extend(to: ids[0], order: ids)
        #expect(model.selected == Set(ids[0 ... 1]))
        #expect(model.lead == ids[0])
    }

    @Test func extendWithoutAnchorSelectsTarget() {
        var model = SelectionModel()
        model.extend(to: ids[2], order: ids)
        #expect(model.selected == [ids[2]])
        #expect(model.anchor == ids[2])
    }

    @Test func extendToHiddenIDIsIgnored() {
        var model = SelectionModel()
        model.select(ids[0])
        model.extend(to: ids[5], order: Array(ids[0 ... 2]))
        #expect(model.selected == [ids[0]])
    }

    @Test func stepCollapsesMultiSelectionFromLead() {
        var model = SelectionModel()
        model.select(ids[1])
        model.extend(to: ids[3], order: ids)
        let lead = model.step(1, order: ids, extending: false)
        #expect(lead == ids[4])
        #expect(model.selected == [ids[4]])
    }

    @Test func stepExtendingGrowsAndShrinksRange() {
        var model = SelectionModel()
        model.select(ids[2])
        model.step(1, order: ids, extending: true)
        model.step(1, order: ids, extending: true)
        #expect(model.selected == Set(ids[2 ... 4]))

        model.step(-1, order: ids, extending: true)
        #expect(model.selected == Set(ids[2 ... 3]))

        // Crossing the anchor flips the range direction.
        model.step(-2, order: ids, extending: true)
        #expect(model.selected == Set(ids[1 ... 2]))
    }

    @Test func stepFromEmptyEntersAtEdge() {
        var model = SelectionModel()
        #expect(model.step(1, order: ids, extending: false) == ids[0])
        model.clear()
        #expect(model.step(-1, order: ids, extending: false) == ids[5])
    }

    @Test func stepClampsAtEdges() {
        var model = SelectionModel()
        model.select(ids[0])
        #expect(model.step(-1, order: ids, extending: false) == ids[0])
        model.select(ids[5])
        #expect(model.step(1, order: ids, extending: false) == ids[5])
    }

    @Test func stepWithEmptyOrderReturnsNil() {
        var model = SelectionModel()
        #expect(model.step(1, order: [], extending: false) == nil)
    }

    @Test func selectAllUsesOrderEndpoints() {
        var model = SelectionModel()
        model.selectAll(order: ids)
        #expect(model.selected == Set(ids))
        #expect(model.anchor == ids.first)
        #expect(model.lead == ids.last)

        model.selectAll(order: [])
        #expect(model.selected == Set(ids))
    }

    @Test func pruneDropsHiddenIDsAndRepairsAnchors() {
        var model = SelectionModel()
        model.select(ids[0])
        model.extend(to: ids[3], order: ids)
        model.prune(order: [ids[1], ids[2]])
        #expect(model.selected == [ids[1], ids[2]])
        // Anchor (ids[0]) and lead (ids[3]) both vanished; repair must land
        // on the first survivor in visible order, not Set iteration order.
        #expect(model.anchor == ids[1])
        #expect(model.lead == ids[1])
    }

    @Test func toggleRemovingAnchorFallsBackToLead() {
        var model = SelectionModel()
        model.select(ids[1])
        model.extend(to: ids[3], order: ids)
        // Removing the anchor: the surviving lead becomes the anchor, so the
        // next shift-click extends from where the cursor is.
        model.toggle(ids[1])
        #expect(model.anchor == ids[3])
        #expect(model.lead == ids[3])
    }

    @Test func toggleRemovingLeadFallsBackToAnchor() {
        var model = SelectionModel()
        model.select(ids[1])
        model.extend(to: ids[3], order: ids)
        model.toggle(ids[3])
        #expect(model.lead == ids[1])
        #expect(model.anchor == ids[1])
    }

    @Test func extendAfterToggleReplacesFromNewAnchor() {
        var model = SelectionModel()
        model.select(ids[0])
        model.toggle(ids[4])
        // Shift-click replaces the selection with the anchor→target range —
        // the disjoint cmd-clicked row at ids[0] is dropped, not unioned.
        model.extend(to: ids[2], order: ids)
        #expect(model.selected == Set(ids[2 ... 4]))
        #expect(model.anchor == ids[4])
        #expect(model.lead == ids[2])
    }

    @Test func pruneToNothingClearsAnchors() {
        var model = SelectionModel()
        model.select(ids[0])
        model.prune(order: [ids[1]])
        #expect(model.isEmpty)
        #expect(model.anchor == nil)
        #expect(model.lead == nil)
    }

    @Test func survivorPrefersItemAfterRemovedBlock() {
        let next = SelectionModel.survivor(afterRemoving: [ids[1], ids[2]], order: ids)
        #expect(next == ids[3])
    }

    @Test func survivorFallsBackToItemBefore() {
        let next = SelectionModel.survivor(afterRemoving: [ids[4], ids[5]], order: ids)
        #expect(next == ids[3])
    }

    @Test func survivorOfEverythingIsNil() {
        #expect(SelectionModel.survivor(afterRemoving: Set(ids), order: ids) == nil)
        #expect(SelectionModel.survivor(afterRemoving: [], order: ids) == nil)
    }

    @Test func survivorHandlesDisjointRemovals() {
        let next = SelectionModel.survivor(afterRemoving: [ids[0], ids[5]], order: ids)
        #expect(next == ids[4])
    }
}
