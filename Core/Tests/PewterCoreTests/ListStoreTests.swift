import Foundation
@testable import PewterCore
import Testing

@MainActor
struct ListStoreTests {
    @Test func addTrimsAndRejectsEmpty() {
        let store = ListStore()
        #expect(store.add(text: "  hello  ")?.text == "hello")
        #expect(store.add(text: "   \n ") == nil)
        #expect(store.items.count == 1)
    }

    @Test func toggleAndDelete() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "toggle me"))

        store.toggleDone(ids: [item.id])
        #expect(store.items[0].done == true)
        store.toggleDone(ids: [item.id])
        #expect(store.items[0].done == false)

        store.delete(ids: [item.id])
        #expect(store.items.isEmpty)
    }

    @Test func mergeJoinsInDocumentOrderAtFirstPosition() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "first"))
        let b = try #require(store.add(text: "second"))
        let c = try #require(store.add(text: "third"))

        // Set input: document order must win regardless of selection order.
        let merged = try #require(store.merge(ids: [c.id, a.id]))

        #expect(merged.text == "first\n\nthird")
        #expect(merged.id == a.id)
        #expect(merged.createdAt == a.createdAt)
        #expect(store.items.map(\.id) == [a.id, b.id])
        #expect(store.items.first?.text == "first\n\nthird")
    }

    @Test func mergeIsDoneOnlyWhenAllSourcesWereDone() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "one"))
        let b = try #require(store.add(text: "two"))

        store.setDone(ids: [a.id], done: true)
        #expect(try #require(store.merge(ids: [a.id, b.id])).done == false)
        _ = store.undoDelete()

        store.setDone(ids: [a.id, b.id], done: true)
        #expect(try #require(store.merge(ids: [a.id, b.id])).done == true)
    }

    @Test func mergeRequiresTwoExistingItems() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "alone"))
        #expect(store.merge(ids: [a.id]) == nil)
        #expect(store.merge(ids: [a.id, UUID()]) == nil)
        #expect(store.items.count == 1)
    }

    @Test func undoAfterMergeRestoresOriginalsExactly() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "keep me"))
        let b = try #require(store.add(text: "absorb me"))
        let c = try #require(store.add(text: "bystander"))
        store.setDone(ids: [b.id], done: true)
        let before = store.document

        _ = try #require(store.merge(ids: [a.id, b.id]))
        let restored = store.undoDelete()

        #expect(store.document == before)
        #expect(Set(restored.map(\.id)) == Set([a.id, b.id]))
        #expect(store.items.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func undoOrderStaysLIFOAcrossMergeAndDelete() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        let c = try #require(store.add(text: "c"))
        let before = store.document

        _ = try #require(store.merge(ids: [a.id, b.id]))
        store.delete(ids: [c.id])

        #expect(store.undoDelete().map(\.id) == [c.id])
        _ = store.undoDelete()
        #expect(store.document == before)
    }

    @Test func redoReappliesDeleteExactly() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "stays"))
        let b = try #require(store.add(text: "goes"))

        store.delete(ids: [b.id])
        let afterDelete = store.document
        _ = store.undoDelete()

        let result = try #require(store.redo())
        #expect(store.document == afterDelete)
        #expect(result.removed.map(\.id) == [b.id])
        #expect(result.mergedProduct == nil)
        #expect(store.items.map(\.id) == [a.id])
    }

    @Test func redoReappliesMergeProductExactly() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "one"))
        let b = try #require(store.add(text: "two"))

        let merged = try #require(store.merge(ids: [a.id, b.id]))
        let afterMerge = store.document
        _ = store.undoDelete()

        let result = try #require(store.redo())
        #expect(store.document == afterMerge)
        #expect(result.mergedProduct == merged)
        #expect(Set(result.removed.map(\.id)) == Set([a.id, b.id]))
    }

    @Test func undoRedoUndoRoundTrips() throws {
        // Redo lands back on the undo stack, so Cmd-Z reverses it again.
        let store = ListStore()
        _ = try #require(store.add(text: "keeper"))
        let victim = try #require(store.add(text: "victim"))
        let before = store.document

        store.delete(ids: [victim.id])
        _ = store.undoDelete()
        _ = store.redo()
        _ = store.undoDelete()

        #expect(store.document == before)
    }

    @Test func redoOrderIsLIFOAcrossMergeAndDelete() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        let c = try #require(store.add(text: "c"))

        _ = try #require(store.merge(ids: [a.id, b.id]))
        store.delete(ids: [c.id])
        let afterBoth = store.document

        _ = store.undoDelete()
        _ = store.undoDelete()

        // Most recently undone replays first: the merge, then the delete.
        #expect(try #require(store.redo()).mergedProduct?.id == a.id)
        #expect(try #require(store.redo()).removed.map(\.id) == [c.id])
        #expect(store.document == afterBoth)
    }

    @Test func freshMutationClearsRedo() throws {
        let store = ListStore()
        let victim = try #require(store.add(text: "victim"))
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        _ = store.add(text: "fork in history")

        #expect(store.redo() == nil)
        #expect(store.items.map(\.text) == ["victim", "fork in history"])
    }

    @Test func toggleDoneClearsRedo() throws {
        let store = ListStore()
        let keeper = try #require(store.add(text: "keeper"))
        let victim = try #require(store.add(text: "victim"))
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.toggleDone(ids: [keeper.id])

        #expect(store.redo() == nil)
        #expect(store.items.count == 2)
    }

    @Test func externalChangeClearsRedo() throws {
        let store = ListStore()
        let victim = try #require(store.add(text: "victim"))
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.applyExternalChange(MarkdownDocument.parse("- [ ] rewritten outside\n"), generation: .initial)

        #expect(store.redo() == nil)
        #expect(store.items.map(\.text) == ["rewritten outside"])
    }

    @Test func deleteClearsRedo() throws {
        // Without the clear, redoing the stale batch would no-op its
        // removal and a later undo would duplicate the note.
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        store.delete(ids: [a.id])
        _ = store.undoDelete()

        store.delete(ids: [b.id])

        #expect(store.redo() == nil)
    }

    @Test func updateTextClearsRedo() throws {
        let store = ListStore()
        let keeper = try #require(store.add(text: "keeper"))
        let victim = try #require(store.add(text: "victim"))
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.updateText(id: keeper.id, text: "renamed")

        #expect(store.redo() == nil)
    }

    @Test func unchangedEditKeepsRedo() throws {
        // Committing an editor without changes is not a mutation.
        let store = ListStore()
        let keeper = try #require(store.add(text: "keeper"))
        let victim = try #require(store.add(text: "victim"))
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.updateText(id: keeper.id, text: "keeper")

        #expect(try #require(store.redo()).removed.map(\.id) == [victim.id])
    }

    @Test func mergeClearsRedo() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        let victim = try #require(store.add(text: "victim"))
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        _ = try #require(store.merge(ids: [a.id, b.id]))

        #expect(store.redo() == nil)
    }

    @Test func partialUndoInterleaveKeepsRestoreOrder() throws {
        // Redo re-appends to the top of the undo stack; a later Cmd-Z must
        // reverse the redo, not an older delete.
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        let before = store.document

        store.delete(ids: [a.id])
        store.delete(ids: [b.id])
        #expect(store.undoDelete().map(\.id) == [b.id])
        #expect(try #require(store.redo()).removed.map(\.id) == [b.id])
        #expect(store.undoDelete().map(\.id) == [b.id])
        #expect(store.undoDelete().map(\.id) == [a.id])
        #expect(store.document == before)
    }

    @Test func redoReappliesMergeAcrossHeadingsExactly() throws {
        // Headings and blanks sit between the sources, so line indices and
        // item indices diverge and redo's index arithmetic is exercised.
        let source = """
        ## A
        - [ ] first
        ## B
        - [ ] second
        - [ ] third
        """
        let store = ListStore(document: MarkdownDocument.parse(source))
        let first = store.items[0]
        let third = store.items[2]
        let before = store.document

        _ = try #require(store.merge(ids: [first.id, third.id]))
        let afterMerge = store.document
        _ = store.undoDelete()

        let result = try #require(store.redo())
        #expect(store.document == afterMerge)
        #expect(result.mergedProduct?.id == first.id)
        _ = store.undoDelete()
        #expect(store.document == before)
    }

    @Test func mergedMultiLineItemRoundTripsThroughSerialization() throws {
        // Whole-second timestamps: ISO8601 metadata drops sub-second
        // precision, so .now would fail the round-trip equality spuriously.
        let created = Date(timeIntervalSince1970: 1_753_000_000)
        let a = Item(id: UUID(), text: "one\n\nstill one", done: false, createdAt: created)
        let b = Item(id: UUID(), text: "two", done: true, createdAt: created)
        let store = ListStore(document: MarkdownDocument(lines: [
            .item(a), .verbatim("## Heading"), .item(b),
        ]))

        let merged = try #require(store.merge(ids: [a.id, b.id]))
        // Blank interior lines are the fragile serializer path: they emit
        // unindented, unlike two-space-indented continuations.
        let reparsed = MarkdownDocument.parse(store.document.serialized())

        #expect(reparsed == store.document)
        #expect(reparsed.items.first?.text == merged.text)
        #expect(reparsed.lines.contains(.heading(SectionHeading(raw: "## Heading", title: "Heading"))))
    }

    @Test func undoAfterMergeRoundTripsThroughSerialization() throws {
        let created = Date(timeIntervalSince1970: 1_753_000_000)
        let a = Item(id: UUID(), text: "alpha", done: false, createdAt: created)
        let b = Item(id: UUID(), text: "beta\ngamma", done: false, createdAt: created)
        let store = ListStore(document: MarkdownDocument(lines: [.item(a), .item(b)]))
        let before = store.document

        _ = try #require(store.merge(ids: [a.id, b.id]))
        _ = store.undoDelete()

        #expect(MarkdownDocument.parse(store.document.serialized()) == before)
    }

    @Test func updatingToEmptyTextDeletes() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "about to vanish"))
        store.updateText(id: item.id, text: "   ")
        #expect(store.items.isEmpty)
    }

    @Test func updateTextRenamesPreservingIdentity() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "original"))
        store.updateText(id: item.id, text: "  renamed\u{2028}second  ")

        let updated = try #require(store.items.first)
        #expect(updated.text == "renamed\nsecond")
        #expect(updated.id == item.id)
        #expect(updated.createdAt == item.createdAt)
    }

    @Test func mutationsPersistThroughStorage() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage(fileURL: url, debounceInterval: 0.05))
        store.add(text: "survives")
        store.flush()

        let reloaded = FileStorage(fileURL: url).load().document
        #expect(reloaded.items.map(\.text) == ["survives"])
    }

    @Test func externalEditReloadsStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "original")
        store.flush()

        try Data("- [ ] edited outside\n".utf8).write(to: url, options: .atomic)

        let deadline = ContinuousClock.now + .seconds(2)
        while store.items.map(\.text) != ["edited outside"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.items.map(\.text) == ["edited outside"])
    }

    @Test func sectionMatchingIsCaseAndDiacriticInsensitive() {
        let store = ListStore()
        store.add(text: "Café notes")
        store.add(text: "unrelated")

        #expect(store.sections(matching: "cafe").flatMap(\.items).count == 1)
        #expect(store.sections(matching: "CAFÉ").flatMap(\.items).count == 1)
        #expect(store.sections(matching: "").flatMap(\.items).count == 2)
        #expect(store.sections(matching: "zzz").isEmpty)
    }

    @Test func sectionsMatchingFiltersWithinAndDropsEmptySections() {
        let store = ListStore(document: MarkdownDocument.parse("""
        ## Research
        - [ ] read paper
        ## Config
        - [ ] tweak paper size
        - [ ] unrelated
        """))

        let filtered = store.sections(matching: "paper")
        #expect(filtered.map(\.heading) == ["Research", "Config"])
        #expect(filtered[1].items.map(\.text) == ["tweak paper size"])
        #expect(store.sections(matching: "zzz").isEmpty)
    }

    @Test func sectionsMatchingEmptyQueryKeepsEmptySections() {
        let store = ListStore(document: MarkdownDocument.parse("## Someday\n"))
        #expect(store.sections(matching: "").map(\.heading) == ["Someday"])
        #expect(store.sections(matching: "   ") == store.sections(matching: ""))
    }

    @Test func headingMatchRevealsTheWholeSection() {
        let store = ListStore(document: MarkdownDocument.parse("## Research\n- [ ] buy milk\n- [ ] call bank\n"))
        let matched = store.sections(matching: "resear")
        #expect(matched.map(\.heading) == ["Research"])
        #expect(matched[0].items.map(\.text) == ["buy milk", "call bank"])

        let empty = ListStore(document: MarkdownDocument.parse("## Someday\n"))
        #expect(empty.sections(matching: "someday").map(\.heading) == ["Someday"])
    }

    @Test func headingAndItemMatchesCombine() {
        let store = ListStore(document: MarkdownDocument.parse("""
        ## Papers
        - [ ] buy milk
        ## Config
        - [ ] paper size
        - [ ] unrelated
        """))
        let matched = store.sections(matching: "paper")
        #expect(matched.map(\.heading) == ["Papers", "Config"])
        #expect(matched[0].items.map(\.text) == ["buy milk"])
        #expect(matched[1].items.map(\.text) == ["paper size"])
    }

    @Test func narrowedSectionsKeepTheirIdentity() {
        let store = ListStore(document: MarkdownDocument.parse("## Research\n- [ ] read paper\n- [ ] other\n"))
        let full = store.sections(matching: "")
        let narrowed = store.sections(matching: "paper")
        #expect(narrowed.map(\.id) == full.map(\.id))
        #expect(narrowed[0].items.map(\.text) == ["read paper"])
    }

    @Test func addedItemJoinsLastSection() {
        let store = ListStore(document: MarkdownDocument.parse("## First\n- [ ] a\n## Last\n- [ ] b\n"))
        store.add(text: "new note")
        #expect(store.sections(matching: "").last?.items.map(\.text) == ["b", "new note"])
    }

    @Test func batchDeleteRemovesAllAndIgnoresUnknownIDs() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        let c = try #require(store.add(text: "c"))

        store.delete(ids: [a.id, c.id, UUID()])
        #expect(store.items.map(\.id) == [b.id])

        store.delete(ids: [])
        #expect(store.items.count == 1)
    }

    @Test func setDoneConvergesMixedSelection() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        store.toggleDone(ids: [a.id])

        store.setDone(ids: [a.id, b.id], done: true)
        #expect(store.items.map(\.done) == [true, true])

        store.setDone(ids: [a.id, b.id], done: false)
        #expect(store.items.map(\.done) == [false, false])
    }

    @Test func toggleDoneIDsConvergesThenFlips() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        store.toggleDone(ids: [a.id])
        #expect(store.allDone(ids: [a.id, b.id]) == false)

        store.toggleDone(ids: [a.id, b.id])
        #expect(store.items.map(\.done) == [true, true])
        #expect(store.allDone(ids: [a.id, b.id]))

        store.toggleDone(ids: [a.id, b.id])
        #expect(store.items.map(\.done) == [false, false])
    }

    @Test func undoRestoresDeletedItemAtPosition() {
        let source = """
        ## Heading
        - [ ] first
        - [x] second
        - [ ] third
        """
        let store = ListStore(document: MarkdownDocument.parse(source))
        let second = store.items[1]

        store.delete(ids: [second.id])
        #expect(store.items.map(\.text) == ["first", "third"])

        let restored = store.undoDelete()
        #expect(restored.map(\.id) == [second.id])
        #expect(store.items.map(\.text) == ["first", "second", "third"])
        #expect(store.items[1].done == true)
        #expect(store.items[1].createdAt == second.createdAt)
        #expect(store.document.lines.first == .heading(SectionHeading(raw: "## Heading", title: "Heading")))
    }

    @Test func undoRestoresBatchAtOriginalPositions() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        store.add(text: "b")
        let c = try #require(store.add(text: "c"))
        store.add(text: "d")

        store.delete(ids: [a.id, c.id])
        #expect(store.items.map(\.text) == ["b", "d"])

        let restored = store.undoDelete()
        // Document order is contract: the UI highlights and scrolls to
        // `restored.first`.
        #expect(restored.map(\.text) == ["a", "c"])
        #expect(store.items.map(\.text) == ["a", "b", "c", "d"])
    }

    @Test func undoRestoresBatchAcrossVerbatimLines() {
        let source = """
        - [ ] a
        ## mid
        - [ ] b
        - [ ] c
        """
        let store = ListStore(document: MarkdownDocument.parse(source))
        let original = store.document

        store.delete(ids: [store.items[0].id, store.items[2].id])
        #expect(store.items.map(\.text) == ["b"])

        #expect(store.undoDelete().map(\.text) == ["a", "c"])
        #expect(store.document == original)
    }

    @Test func repeatedUndoWalksBackThroughDeletes() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))

        store.delete(ids: [a.id])
        store.delete(ids: [b.id])
        #expect(store.items.isEmpty)

        #expect(store.undoDelete().map(\.text) == ["b"])
        #expect(store.undoDelete().map(\.text) == ["a"])
        #expect(store.items.map(\.text) == ["a", "b"])
        #expect(store.undoDelete().isEmpty)
    }

    @Test func undoWithNoHistoryReturnsEmpty() {
        let store = ListStore()
        store.add(text: "untouched")
        // A delete matching nothing must not consume an undo slot.
        store.delete(ids: [UUID()])
        #expect(store.undoDelete().isEmpty)
        #expect(store.items.count == 1)
    }

    @Test func undoHistoryIsCapped() throws {
        let store = ListStore()
        for index in 1 ... 12 {
            let item = try #require(store.add(text: "note \(index)"))
            store.delete(ids: [item.id])
        }

        var restoredCount = 0
        while !store.undoDelete().isEmpty {
            restoredCount += 1
        }
        #expect(restoredCount == 10)
        #expect(store.items.map(\.text) == (3 ... 12).map { "note \($0)" })
    }

    @Test func updateTextToEmptyIsUndoable() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "oops"))
        store.updateText(id: item.id, text: "   ")
        #expect(store.items.isEmpty)

        #expect(store.undoDelete().map(\.id) == [item.id])
        #expect(store.items.map(\.text) == ["oops"])
    }

    @Test func undoPersistsThroughStorage() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage(fileURL: url))
        let item = try #require(store.add(text: "keep me"))
        store.delete(ids: [item.id])
        _ = store.undoDelete()
        store.flush()

        let reloaded = FileStorage(fileURL: url).load().document
        #expect(reloaded.items.map(\.text) == ["keep me"])
    }

    @Test func applyExternalChangeClearsUndoHistory() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "deleted in app"))
        store.delete(ids: [item.id])

        store.applyExternalChange(MarkdownDocument.parse("- [ ] rewritten outside\n"), generation: .initial)
        #expect(store.items.map(\.text) == ["rewritten outside"])
        #expect(store.undoDelete().isEmpty)
    }

    @Test func externalEditClearsUndoHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage(fileURL: url))
        store.add(text: "a")
        let b = try #require(store.add(text: "b"))
        store.flush()

        store.delete(ids: [b.id])
        try Data("- [ ] rewritten\n".utf8).write(to: url, options: .atomic)

        let deadline = ContinuousClock.now + .seconds(2)
        while store.items.map(\.text) != ["rewritten"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.items.map(\.text) == ["rewritten"])
        #expect(store.undoDelete().isEmpty)
    }

    @Test func batchMutationsPersistThroughStorage() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        let a = try #require(store.add(text: "a"))
        let b = try #require(store.add(text: "b"))
        let c = try #require(store.add(text: "c"))

        store.setDone(ids: [a.id, b.id], done: true)
        store.delete(ids: [c.id])
        store.flush()

        let reloaded = ListStore.loadFrom(storage: FileStorage(fileURL: url))
        #expect(reloaded.items.map(\.text) == ["a", "b"])
        #expect(reloaded.items.map(\.done) == [true, true])
    }

    /// An unreadable file yields an empty document that is not the user's
    /// notes. Marking it lets surfaces refuse input they would have to throw
    /// away, instead of presenting a blank list as if it were real.
    @Test func loadingAnUnreadableFileMarksTheDocumentAsAPlaceholder() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.items.isEmpty)
        #expect(store.documentIsPlaceholder)

        // Adopting real content makes the document stand for itself again.
        store.applyExternalChange(MarkdownDocument.parse("- [ ] real note\n"), generation: .initial)
        #expect(!store.documentIsPlaceholder)
        #expect(store.items.map(\.text) == ["real note"])
    }

    /// Every input is refused while the document is a placeholder, and a save
    /// is the only other thing that re-reads the file — so without this the
    /// app would insist it can't read repaired notes until the next launch.
    @Test func reloadingRecoversAPlaceholderOnceTheFileIsReadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.documentIsPlaceholder)

        // Still unreadable: reloading must not pretend it recovered.
        store.reloadIfPlaceholder()
        #expect(store.documentIsPlaceholder)
        #expect(store.items.isEmpty)

        try Data("- [ ] repaired by hand\n".utf8).write(to: url, options: .atomic)
        store.reloadIfPlaceholder()
        #expect(!store.documentIsPlaceholder)
        #expect(store.items.map(\.text) == ["repaired by hand"])

        // And saving works again, on the generation the reload handed back.
        store.add(text: "typed after recovery")
        store.flush()
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["repaired by hand", "typed after recovery"])
    }

    /// Reloading must clear the banner too. The banner is driven by health,
    /// the list by the placeholder flag, and the design assumes they converge
    /// on recovery — recovered notes under a "can't be read" banner is the
    /// failure this pins.
    @Test func reloadingClearsTheSuspensionBannerAsWellAsThePlaceholder() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        #expect(storage.health == .unreadable)

        try Data("- [ ] repaired\n".utf8).write(to: url, options: .atomic)
        store.reloadIfPlaceholder()
        #expect(!store.documentIsPlaceholder)
        #expect(storage.health == .ok)
    }

    /// The worst clobber available: a placeholder holds nothing, so writing it
    /// over a file repaired behind the app's back trades the user's real notes
    /// for an empty document. Quit is when it would happen, since the flush
    /// runs with no chance to reload first.
    @Test func flushingAPlaceholderNeverClobbersAFileRepairedBehindTheApp() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.documentIsPlaceholder)

        // Unwatched on purpose: the app never learns of the repair, so the
        // flush is the first thing to look at the file again.
        let repaired = Data("- [ ] the user's real notes\n".utf8)
        try repaired.write(to: url, options: .atomic)

        store.flush()

        #expect(try Data(contentsOf: url) == repaired)
    }

    /// The retry has to cover the runtime break, not just the placeholder: a
    /// capture-only user never opens the panel, so if this path can't clear a
    /// repaired file the HUD keeps refusing notes until the app is relaunched.
    @Test func retryingRecoversAfterTheFileBreaksAndIsRepairedAtRuntime() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "real note")
        store.flush()
        // The app's own bytes. A permission repair restores exactly these —
        // the content never changed, only the ability to read it — so the
        // recovery must take the `.ours` path and keep what's in memory.
        let ourBytes = try Data(contentsOf: url)

        // Unwatched throughout: the app only ever learns about the file by
        // looking at it, which is what the retry is for.
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.add(text: "typed after the break")
        store.flush()
        #expect(storage.health == .unreadable)
        #expect(!store.documentIsPlaceholder, "a runtime break must not raise the placeholder flag")
        #expect(store.inputWouldBeDiscarded)

        try ourBytes.write(to: url, options: .atomic)
        store.retryUnavailableStorage()

        #expect(!store.inputWouldBeDiscarded)
        #expect(storage.health == .ok)
        // The note typed while saving was suspended has to survive the
        // recovery — re-reading the file instead would silently drop it.
        #expect(store.items.map(\.text) == ["real note", "typed after the break"])

        // The capture the retry cleared the way for, and everything held in
        // memory behind it, reach disk together.
        store.add(text: "captured after recovery")
        store.flush()
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["real note", "typed after the break", "captured after recovery"])
    }

    /// The break is invisible until something looks: no save has failed yet,
    /// so health still reads `.ok` about a file that is already unreadable.
    /// Without the retry reconciling first, the very next capture reports
    /// "Captured" for a note that dies at quit.
    @Test func theFirstInputAfterAnUnnoticedBreakIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "real note")
        store.flush()
        #expect(storage.health == .ok)

        // Broken behind the app's back, with nothing written since — exactly
        // what a `chmod` leaves behind, which fires no watcher event.
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        #expect(storage.health == .ok, "nothing has looked at the file yet")
        #expect(!store.inputWouldBeDiscarded, "and so nothing knows to refuse")

        store.retryUnavailableStorage()

        #expect(storage.health == .unreadable)
        #expect(store.inputWouldBeDiscarded)
    }

    /// Recovering by adopting leaves the store a generation behind until the
    /// delivery lands, and that delivery replaces the document. Health is
    /// `.ok` throughout, so nothing else here would stop a capture from
    /// reporting success for a note the adoption is about to discard.
    @Test func inputIsRefusedWhileAnAdoptionIsStillInFlight() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "real note")
        store.flush()

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.add(text: "typed after the break")
        store.flush()
        #expect(storage.health == .unreadable)

        // Repaired by rewriting with different content: foreign, so the retry
        // adopts rather than overwriting.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)
        store.retryUnavailableStorage()

        #expect(storage.health == .ok)
        #expect(store.inputWouldBeDiscarded)
    }

    /// A clean quit says nothing. The quit-time warning is the last evidence a
    /// "where did my notes go" report ever gets, so a false one sends the
    /// reader hunting a loss that never happened.
    @Test func aFlushThatLandsReportsNoLoss() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        store.add(text: "a note")

        #expect(store.flush() == false)
        // The absence of a warning is not evidence of a save; without this the
        // test survives deleting the save from flush() altogether.
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text) == ["a note"])
    }

    /// The case the warning exists for: the file never became writable, so
    /// everything held in memory dies here.
    @Test func aFlushOntoAnUnreadableFileReportsLoss() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "a note")
        store.flush()

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.add(text: "typed after the break")

        #expect(store.flush() == true)
        #expect(storage.health == .unreadable)
    }

    /// The flush itself is what resolves the suspension here, so a warning read
    /// before it would assert a loss that the very same call prevents. This is
    /// the likeliest repair of all — restoring the app's own bytes, which fires
    /// no watcher event and so is noticed by nothing until something writes.
    @Test func aFlushThatResolvesTheSuspensionReportsNoLoss() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "a note")
        store.flush()
        let ourBytes = try Data(contentsOf: url)

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.add(text: "typed after the break")
        store.flush()
        #expect(storage.health == .unreadable)

        try ourBytes.write(to: url, options: .atomic)

        // False only if read after the save: health is still `.unreadable`
        // going in, and this call is what clears it.
        #expect(store.flush() == false)
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["a note", "typed after the break"])
    }

    /// Health is `.ok` and the file reads perfectly, yet the notes are gone —
    /// the adopted document replaces them on delivery. Reading health alone
    /// reports success for the one case that silently loses input, and the
    /// adoption is triggered by this very save, so sampling before it would
    /// report success too.
    @Test func aFlushRefusedForAnInFlightAdoptionReportsLoss() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "a note")
        #expect(store.flush() == false)

        // Foreign content, with storage healthy and level going in: the save
        // itself is what adopts and moves the generation on.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)

        #expect(store.flush() == true)
        #expect(storage.health == .ok)
    }

    /// A write that fails is loss at quit even though it may be transient —
    /// `inputWouldBeDiscarded` excludes `.saveFailed` because a later debounce
    /// may land, and at quit there is no later debounce. Nothing else pins that
    /// divergence, so unifying the two predicates would pass silently.
    @Test func aFlushThatCannotWriteReportsLoss() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A file where the notes directory should be, so creating it throws.
        let blocker = root.appending(path: "blocker")
        try Data("not a directory".utf8).write(to: blocker, options: .atomic)

        let storage = FileStorage.unwatched(fileURL: blocker.appending(path: "notes.md"))
        let store = ListStore.loadFrom(storage: storage)
        store.add(text: "a note")

        #expect(store.flush() == true)
        #expect(storage.health != .ok)
        #expect(storage.health != .unreadable)
    }

    /// The guard is what keeps the reload off the hot path: it runs on every
    /// panel summon and every capture, and adopting unconditionally would
    /// re-read the file and wipe undo each time.
    @Test func reloadingIsANoOpWhenTheDocumentIsReal() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        let item = try #require(store.add(text: "deletable"))
        store.delete(ids: [item.id])

        store.reloadIfPlaceholder()

        #expect(!store.undoDelete().isEmpty)
        #expect(store.items.map(\.text) == ["deletable"])
    }

    /// A readable but genuinely empty file is not a placeholder — a fresh
    /// install must keep accepting notes.
    @Test func loadingAnEmptyFileIsNotAPlaceholder() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Zero bytes, which is what a fresh install leaves after its first
        // save — readable, so not a placeholder.
        try Data().write(to: url)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.items.isEmpty)
        #expect(!store.documentIsPlaceholder)
    }

    @Test func loadingWhenNoFileExistsIsNotAPlaceholder() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.items.isEmpty)
        #expect(!store.documentIsPlaceholder)
    }

    /// Completes the loop the storage tests stop halfway through: an external
    /// edit lands, the store applies it, and the user keeps typing. The store
    /// has to carry the generation it was handed or every save from here on is
    /// refused for the life of the process, with the file silently frozen.
    @Test func editsAfterAnExternalReloadStillReachDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage(fileURL: url, debounceInterval: 0.05))
        store.add(text: "original")
        store.flush()

        try Data("- [ ] edited outside\n".utf8).write(to: url, options: .atomic)
        let deadline = ContinuousClock.now + .seconds(2)
        while store.items.map(\.text) != ["edited outside"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.items.map(\.text) == ["edited outside"])

        // The debounced path every user edit takes.
        store.add(text: "typed after reload")
        try await Task.sleep(for: .milliseconds(300))
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["edited outside", "typed after reload"])

        // And the quit flush.
        store.add(text: "typed before quit")
        store.flush()
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["edited outside", "typed after reload", "typed before quit"])
    }

    /// A store built against a storage that has already adopted an external
    /// change must take the generation `load()` hands back, or it starts
    /// behind and nothing can ever move it forward.
    @Test func aStoreRebuiltAfterAnAdoptionSavesOnTheLoadedGeneration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var seeded = MarkdownDocument()
        seeded.append(Item(text: "original"))
        storage.saveNow(seeded, generation: .initial)

        // An earlier store adopts an external edit, then goes away.
        storage.setOnExternalChange { _, _ in }
        try Data("- [ ] outside edit\n".utf8).write(to: url, options: .atomic)
        storage.saveNow(seeded, generation: .initial)
        try await Task.sleep(for: .milliseconds(150))

        let store = ListStore.loadFrom(storage: storage)
        #expect(store.items.map(\.text) == ["outside edit"])
        store.add(text: "typed after rebuild")
        store.flush()
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["outside edit", "typed after rebuild"])
    }
}
