@testable import PewterCore
import Testing

struct PanelCommandsTests {
    @Test func escapeLadderUnwindsInOrder() {
        #expect(PanelCommands.escapeAction(
            guideShowing: true, selectionIsMultiple: true, filterActive: true
        ) == .closeGuide)
        #expect(PanelCommands.escapeAction(
            guideShowing: false, selectionIsMultiple: true, filterActive: true
        ) == .clearSelection)
        #expect(PanelCommands.escapeAction(
            guideShowing: false, selectionIsMultiple: false, filterActive: true
        ) == .clearFilter)
        // Only a multi-selection climbs the ladder — quick-add selects what
        // it added, and capture-then-Esc must still hide the panel in one
        // press.
        #expect(PanelCommands.escapeAction(
            guideShowing: false, selectionIsMultiple: false, filterActive: false
        ) == .hidePanel)
    }

    @Test func listCopyNarrowsToMultiSelection() {
        let visible = (1 ... 4).map { Item(text: "note \($0)") }
        let selected = Array(visible[0 ... 1])
        #expect(PanelCommands.listCopyTargets(selected: selected, visible: visible) == selected)
    }

    @Test func listCopyUsesVisibleListForSingleOrEmptySelection() {
        let visible = (1 ... 4).map { Item(text: "note \($0)") }
        #expect(PanelCommands.listCopyTargets(selected: [visible[0]], visible: visible) == visible)
        #expect(PanelCommands.listCopyTargets(selected: [], visible: visible) == visible)
    }

    @Test func listCopyOfNothingIsEmpty() {
        #expect(PanelCommands.listCopyTargets(selected: [], visible: []).isEmpty)
    }
}
