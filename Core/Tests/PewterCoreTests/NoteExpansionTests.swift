import Foundation
@testable import PewterCore
import Testing

struct NoteExpansionTests {
    let ids = (0 ..< 4).map { _ in UUID() }

    @Test func startsCollapsed() {
        let model = NoteExpansion()
        #expect(!model.isExpanded(ids[0]))
    }

    @Test func toggleExpandsAndCollapsesOneNote() {
        var model = NoteExpansion()
        let firstPress = model.toggle([ids[0]])
        #expect(!firstPress)
        #expect(model.isExpanded(ids[0]))
        let secondPress = model.toggle([ids[0]])
        #expect(secondPress)
        #expect(!model.isExpanded(ids[0]))
    }

    @Test func mixedSelectionExpandsAllBeforeCollapsing() {
        var model = NoteExpansion()
        model.toggle([ids[0]])
        let firstPress = model.toggle([ids[0], ids[1]])
        #expect(!firstPress)
        #expect(model.isExpanded(ids[0]))
        #expect(model.isExpanded(ids[1]))
        let secondPress = model.toggle([ids[0], ids[1]])
        #expect(secondPress)
        #expect(!model.isExpanded(ids[0]))
        #expect(!model.isExpanded(ids[1]))
    }

    @Test func toggleLeavesOtherNotesAlone() {
        var model = NoteExpansion()
        model.toggle([ids[0]])
        model.toggle([ids[1], ids[2]])
        #expect(model.isExpanded(ids[0]))
        model.toggle([ids[1], ids[2]])
        #expect(model.isExpanded(ids[0]))
        #expect(!model.isExpanded(ids[1]))
    }

    @Test func expansionIsPerNoteNotPerToggleGroup() {
        var model = NoteExpansion()
        model.toggle([ids[0]])
        model.toggle([ids[1]])
        model.toggle([ids[0], ids[1]])
        #expect(!model.isExpanded(ids[0]))
        #expect(!model.isExpanded(ids[1]))
    }

    @Test func emptySelectionIsANoOp() {
        var model = NoteExpansion()
        model.toggle([ids[0]])
        let before = model
        // Not a collapse either — an empty set must not trigger callers'
        // collapse handling.
        let collapsed = model.toggle([])
        #expect(!collapsed)
        #expect(model == before)
    }
}
