import Foundation
@testable import PewterCore
import Testing

/// Resumes a continuation at most once: health is delivered on registration
/// and again on every change, and a second resume traps.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume()
    }
}

@MainActor
struct ListStoreTests {
    @Test func addTrimsAndRejectsEmpty() {
        let store = ListStore()
        // Matched rather than unwrapped via `.item`: this test is about `add`
        // itself, and `.item` is for tests whose subject is what comes after.
        guard case let .added(item) = store.add(text: "  hello  ") else {
            Issue.record("expected the add to land")
            return
        }
        #expect(item.text == "hello")
        #expect(store.add(text: "   \n ") == .emptyText)
        #expect(store.items.count == 1)
    }

    /// The two failures need opposite messages — "nothing to add" is about the
    /// input, a refusal is about the file — and an optional return made them
    /// indistinguishable, so a caller inferring from nil reported whichever it
    /// happened to assume.
    @Test func addSeparatesEmptyTextFromARefusal() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.add(text: "real text with nowhere to go")
            == .refused(.unreadable(cause: .notUTF8)))
        // Whitespace on a broken file is still nothing to add: naming a repair
        // for text that was never going to be stored sends the user to fix
        // something that would not have helped.
        #expect(store.add(text: "   ") == .emptyText)
        #expect(store.items.isEmpty)
    }

    @Test func toggleAndDelete() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "toggle me").item)

        store.toggleDone(ids: [item.id])
        #expect(store.items[0].done == true)
        store.toggleDone(ids: [item.id])
        #expect(store.items[0].done == false)

        store.delete(ids: [item.id])
        #expect(store.items.isEmpty)
    }

    @Test func mergeJoinsInDocumentOrderAtFirstPosition() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "first").item)
        let b = try #require(store.add(text: "second").item)
        let c = try #require(store.add(text: "third").item)

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
        let a = try #require(store.add(text: "one").item)
        let b = try #require(store.add(text: "two").item)

        store.setDone(ids: [a.id], done: true)
        #expect(try #require(store.merge(ids: [a.id, b.id])).done == false)
        _ = store.undoDelete()

        store.setDone(ids: [a.id, b.id], done: true)
        #expect(try #require(store.merge(ids: [a.id, b.id])).done == true)
    }

    @Test func mergeRequiresTwoExistingItems() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "alone").item)
        #expect(store.merge(ids: [a.id]) == nil)
        #expect(store.merge(ids: [a.id, UUID()]) == nil)
        #expect(store.items.count == 1)
    }

    @Test func undoAfterMergeRestoresOriginalsExactly() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "keep me").item)
        let b = try #require(store.add(text: "absorb me").item)
        let c = try #require(store.add(text: "bystander").item)
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
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        let c = try #require(store.add(text: "c").item)
        let before = store.document

        _ = try #require(store.merge(ids: [a.id, b.id]))
        store.delete(ids: [c.id])

        #expect(store.undoDelete().map(\.id) == [c.id])
        _ = store.undoDelete()
        #expect(store.document == before)
    }

    @Test func redoReappliesDeleteExactly() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "stays").item)
        let b = try #require(store.add(text: "goes").item)

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
        let a = try #require(store.add(text: "one").item)
        let b = try #require(store.add(text: "two").item)

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
        _ = try #require(store.add(text: "keeper").item)
        let victim = try #require(store.add(text: "victim").item)
        let before = store.document

        store.delete(ids: [victim.id])
        _ = store.undoDelete()
        _ = store.redo()
        _ = store.undoDelete()

        #expect(store.document == before)
    }

    @Test func redoOrderIsLIFOAcrossMergeAndDelete() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        let c = try #require(store.add(text: "c").item)

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
        let victim = try #require(store.add(text: "victim").item)
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        _ = store.add(text: "fork in history")

        #expect(store.redo() == nil)
        #expect(store.items.map(\.text) == ["victim", "fork in history"])
    }

    @Test func toggleDoneClearsRedo() throws {
        let store = ListStore()
        let keeper = try #require(store.add(text: "keeper").item)
        let victim = try #require(store.add(text: "victim").item)
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.toggleDone(ids: [keeper.id])

        #expect(store.redo() == nil)
        #expect(store.items.count == 2)
    }

    @Test func externalChangeClearsRedo() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        let victim = try #require(store.add(text: "victim").item)
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.applyExternalChange(
            MarkdownDocument.parse("- [ ] rewritten outside\n"),
            generation: storage.load().generation
        )

        #expect(store.redo() == nil)
        #expect(store.items.map(\.text) == ["rewritten outside"])
    }

    @Test func deleteClearsRedo() throws {
        // Without the clear, redoing the stale batch would no-op its
        // removal and a later undo would duplicate the note.
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        store.delete(ids: [a.id])
        _ = store.undoDelete()

        store.delete(ids: [b.id])

        #expect(store.redo() == nil)
    }

    @Test func updateTextClearsRedo() throws {
        let store = ListStore()
        let keeper = try #require(store.add(text: "keeper").item)
        let victim = try #require(store.add(text: "victim").item)
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.updateText(id: keeper.id, text: "renamed")

        #expect(store.redo() == nil)
    }

    @Test func unchangedEditKeepsRedo() throws {
        // Committing an editor without changes is not a mutation.
        let store = ListStore()
        let keeper = try #require(store.add(text: "keeper").item)
        let victim = try #require(store.add(text: "victim").item)
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        store.updateText(id: keeper.id, text: "keeper")

        #expect(try #require(store.redo()).removed.map(\.id) == [victim.id])
    }

    @Test func mergeClearsRedo() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        let victim = try #require(store.add(text: "victim").item)
        store.delete(ids: [victim.id])
        _ = store.undoDelete()

        _ = try #require(store.merge(ids: [a.id, b.id]))

        #expect(store.redo() == nil)
    }

    @Test func partialUndoInterleaveKeepsRestoreOrder() throws {
        // Redo re-appends to the top of the undo stack; a later Cmd-Z must
        // reverse the redo, not an older delete.
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
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
        let item = try #require(store.add(text: "about to vanish").item)
        store.updateText(id: item.id, text: "   ")
        #expect(store.items.isEmpty)
    }

    @Test func updateTextRenamesPreservingIdentity() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "original").item)
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
        _ = store.add(text: "survives")
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
        _ = store.add(text: "original")
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
        _ = store.add(text: "Café notes")
        _ = store.add(text: "unrelated")

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
        _ = store.add(text: "new note")
        #expect(store.sections(matching: "").last?.items.map(\.text) == ["b", "new note"])
    }

    @Test func batchDeleteRemovesAllAndIgnoresUnknownIDs() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        let c = try #require(store.add(text: "c").item)

        store.delete(ids: [a.id, c.id, UUID()])
        #expect(store.items.map(\.id) == [b.id])

        store.delete(ids: [])
        #expect(store.items.count == 1)
    }

    @Test func setDoneConvergesMixedSelection() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        store.toggleDone(ids: [a.id])

        store.setDone(ids: [a.id, b.id], done: true)
        #expect(store.items.map(\.done) == [true, true])

        store.setDone(ids: [a.id, b.id], done: false)
        #expect(store.items.map(\.done) == [false, false])
    }

    @Test func toggleDoneIDsConvergesThenFlips() throws {
        let store = ListStore()
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
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
        let a = try #require(store.add(text: "a").item)
        _ = store.add(text: "b")
        let c = try #require(store.add(text: "c").item)
        _ = store.add(text: "d")

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
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)

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
        _ = store.add(text: "untouched")
        // A delete matching nothing must not consume an undo slot.
        store.delete(ids: [UUID()])
        #expect(store.undoDelete().isEmpty)
        #expect(store.items.count == 1)
    }

    @Test func undoHistoryIsCapped() throws {
        let store = ListStore()
        for index in 1 ... 12 {
            let item = try #require(store.add(text: "note \(index)").item)
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
        let item = try #require(store.add(text: "oops").item)
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
        let item = try #require(store.add(text: "keep me").item)
        store.delete(ids: [item.id])
        _ = store.undoDelete()
        store.flush()

        let reloaded = FileStorage(fileURL: url).load().document
        #expect(reloaded.items.map(\.text) == ["keep me"])
    }

    @Test func applyExternalChangeClearsUndoHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        let item = try #require(store.add(text: "deleted in app").item)
        store.delete(ids: [item.id])

        store.applyExternalChange(
            MarkdownDocument.parse("- [ ] rewritten outside\n"),
            generation: storage.load().generation
        )
        #expect(store.items.map(\.text) == ["rewritten outside"])
        #expect(store.undoDelete().isEmpty)
    }

    @Test func externalEditClearsUndoHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage(fileURL: url))
        _ = store.add(text: "a")
        let b = try #require(store.add(text: "b").item)
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
        let a = try #require(store.add(text: "a").item)
        let b = try #require(store.add(text: "b").item)
        let c = try #require(store.add(text: "c").item)

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

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        #expect(store.items.isEmpty)
        #expect(store.documentIsPlaceholder)

        // Adopting real content makes the document stand for itself again.
        // The generation comes from storage: a delivery the store has already
        // moved past is dropped, so a hardcoded baseline would never land.
        store.applyExternalChange(
            MarkdownDocument.parse("- [ ] real note\n"),
            generation: storage.load().generation
        )
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
        _ = store.add(text: "typed after recovery")
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
        #expect(storage.health == .unreadable(cause: .notUTF8))

        try Data("- [ ] repaired\n".utf8).write(to: url, options: .atomic)
        store.reloadIfPlaceholder()
        #expect(!store.documentIsPlaceholder)
        #expect(storage.health == .ok)
        // And synchronously on the mirror, or the panel this reload was run
        // for keeps the banner the reload has now cleared.
        #expect(store.health == .ok)
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
        _ = store.add(text: "real note")
        store.flush()
        // The app's own bytes. A permission repair restores exactly these —
        // the content never changed, only the ability to read it — so the
        // recovery must take the `.ours` path and keep what's in memory.
        let ourBytes = try Data(contentsOf: url)

        // Unwatched throughout: the app only ever learns about the file by
        // looking at it, which is what the retry is for.
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        _ = store.add(text: "typed after the break")
        store.flush()
        #expect(storage.health == .unreadable(cause: .notUTF8))
        #expect(!store.documentIsPlaceholder, "a runtime break must not raise the placeholder flag")
        #expect(store.unavailability == .unreadable(cause: .notUTF8))

        try ourBytes.write(to: url, options: .atomic)
        store.retryUnavailableStorage()

        #expect(store.unavailability == nil)
        #expect(storage.health == .ok)
        // The note typed while saving was suspended has to survive the
        // recovery — re-reading the file instead would silently drop it.
        #expect(store.items.map(\.text) == ["real note", "typed after the break"])

        // The capture the retry cleared the way for, and everything held in
        // memory behind it, reach disk together.
        _ = store.add(text: "captured after recovery")
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
        _ = store.add(text: "real note")
        store.flush()
        #expect(storage.health == .ok)

        // Broken behind the app's back, with nothing written since — exactly
        // what a `chmod` leaves behind, which fires no watcher event.
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        #expect(storage.health == .ok, "nothing has looked at the file yet")
        #expect(store.unavailability == nil, "and so nothing knows to refuse")

        store.retryUnavailableStorage()

        #expect(storage.health == .unreadable(cause: .notUTF8))
        #expect(store.unavailability == .unreadable(cause: .notUTF8))
        // Synchronously, with no queue drain: a summon retries and draws in
        // one turn, so a mirror left to the storage's own notification would
        // paint the panel with no banner over the break it has now found.
        #expect(store.health == .unreadable(cause: .notUTF8))
    }

    /// Not every adoption is drained: a debounced save that finds foreign
    /// content adopts and leaves the store behind with nothing to rebase it
    /// until the delivery lands. Health is `.ok` and the file reads perfectly
    /// throughout, so the generation is the only thing that knows input
    /// accepted now would be replaced.
    ///
    /// The reason is the point, not merely the refusal: reporting "the notes
    /// file can't be read" here would blame a file with nothing wrong with it
    /// and send the user to re-check permissions when the window closes by
    /// itself on the next turn.
    @Test func inputIsRefusedWhileAnAdoptionIsStillInFlight() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "real note")
        store.flush()

        // Foreign content, adopted by the save itself rather than by a retry.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)
        store.flush()

        #expect(storage.health == .ok)
        #expect(store.unavailability == .adoptionInFlight)

        // And the refusal a surface would show says so, rather than blaming a
        // file that reads perfectly.
        #expect(store.add(text: "typed into the window") == .refused(.adoptionInFlight))
        #expect(CaptureFeedback.notesUnavailable(.adoptionInFlight).message
            == "Your notes just changed on disk — capture again")
    }

    /// The capture that triggers an adoption used to be refused and told the
    /// notes file couldn't be read — while the file read perfectly and the
    /// real remedy was "capture again". The retry drains the adoption so it
    /// lands instead.
    @Test func aCaptureThatTriggersAnAdoptionStillLands() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a note")
        store.flush()

        try Data("- [ ] edited outside\n".utf8).write(to: url, options: .atomic)

        // What a capture does before deciding whether to refuse.
        store.retryUnavailableStorage()

        #expect(storage.health == .ok)
        #expect(store.unavailability == nil, "the file reads fine; refusing here blames the wrong thing")
        #expect(store.items.map(\.text) == ["edited outside"])

        _ = store.add(text: "captured after the adoption")
        store.flush()
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["edited outside", "captured after the adoption"])
    }

    /// A clean quit says nothing. The quit-time warning is the last evidence a
    /// "where did my notes go" report ever gets, so a false one sends the
    /// reader hunting a loss that never happened.
    @Test func aFlushThatLandsReportsNoLoss() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        _ = store.add(text: "a note")

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
        _ = store.add(text: "a note")
        store.flush()

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        _ = store.add(text: "typed after the break")

        #expect(store.flush() == true)
        #expect(storage.health == .unreadable(cause: .notUTF8))
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
        _ = store.add(text: "a note")
        store.flush()
        let ourBytes = try Data(contentsOf: url)

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        _ = store.add(text: "typed after the break")
        store.flush()
        #expect(storage.health == .unreadable(cause: .notUTF8))

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
        _ = store.add(text: "a note")
        #expect(store.flush() == false)

        // Foreign content, with storage healthy and level going in: the save
        // itself is what adopts and moves the generation on.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)

        #expect(store.flush() == true)
        #expect(storage.health == .ok)
    }

    /// A write that fails is loss at quit even though it may be transient —
    /// `unavailability` excludes `.saveFailed` because a later debounce
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
        _ = store.add(text: "a note")

        #expect(store.flush() == true)
        #expect(storage.health != .ok)
        // Not merely "not this one cause": the point is that a write failure
        // is not a suspension at all. Comparing against a single case would
        // now pass for any other one.
        #expect(storage.health.unreadableCause == nil)
    }

    /// A reload takes what is on disk and moves the store forward, but a
    /// watcher adoption may already have a delivery in flight carrying the
    /// generation the reload lands on. Applying it replaces the document and
    /// takes anything added since with it — the capture that triggered the
    /// reload most of all.
    @Test func aDeliveryTheStoreHasAlreadyAppliedIsDropped() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        // Every generation is minted exactly once, so a delivery in flight
        // always carries a strictly lower value than the reload that
        // superseded it — never an equal one. Two distinct mints applied out
        // of order are the shape the guard has to survive.
        let inFlight = storage.load().generation
        let reload = storage.load().generation

        store.applyExternalChange(MarkdownDocument.parse("- [ ] from disk\n"), generation: reload)
        _ = store.add(text: "typed after the reload")

        store.applyExternalChange(MarkdownDocument.parse("- [ ] from disk\n"), generation: inFlight)

        #expect(store.items.map(\.text) == ["from disk", "typed after the reload"])
    }

    /// What makes the drop above possible: a reload that handed back the
    /// generation it found would be indistinguishable from the delivery racing
    /// it, and there would be nothing to compare.
    @Test func loadTakesAFreshGenerationSoAnInFlightDeliveryIsOutranked() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        #expect(storage.load().generation < storage.load().generation)
    }

    /// Drives the real race rather than simulating it: a genuine adoption is
    /// queued, a reload supersedes it, and a note is added in the window
    /// between. Registering for health after the adoption queues a callback
    /// behind the delivery on the same serial event queue, so awaiting it is a
    /// barrier — no sleeps, and it rests on the same FIFO ordering production
    /// already depends on.
    @Test func aDeliveryQueuedBeforeAReloadLosesToItEndToEnd() async throws {
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
        #expect(store.documentIsPlaceholder)

        try Data("- [ ] repaired by hand\n".utf8).write(to: url, options: .atomic)

        // Foreign content, so this is a real adoption with a real delivery in
        // flight. Main is held by this test body until the await below.
        store.flush()
        store.reloadIfPlaceholder()
        _ = store.add(text: "captured in the window")

        await waitForPendingDeliveries(of: storage)
        #expect(store.items.map(\.text) == ["repaired by hand", "captured in the window"])

        // Positive control: a delivery the store has NOT moved past still
        // applies. Without it, a barrier that stopped working would leave the
        // assertion above passing for the wrong reason.
        try Data("- [ ] later external edit\n".utf8).write(to: url, options: .atomic)
        store.flush()
        await waitForPendingDeliveries(of: storage)
        #expect(store.items.map(\.text) == ["later external edit"])
    }

    /// Returns once anything queued on the storage's event queue before the
    /// call has been delivered and applied on the main queue.
    private func waitForPendingDeliveries(of storage: FileStorage) async {
        let once = ResumeOnce()
        await withCheckedContinuation { continuation in
            storage.setOnHealthChange { _ in
                DispatchQueue.main.async { once.resume(continuation) }
            }
        }
    }

    /// A break landing while the store is behind is not a reason to replace
    /// the document: there is nothing readable to take up, so the real notes
    /// and the refusal that protects them both have to survive the retry.
    @Test func aRetryLeavesTheDocumentAloneWhenTheFileBreaksWhileBehind() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()

        // Behind: the save adopted foreign content and the delivery has not
        // arrived, so nothing has rebased this store.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)
        store.flush()
        #expect(store.unavailability == .adoptionInFlight)

        // And now the file breaks, before the retry runs.
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.retryUnavailableStorage()

        #expect(storage.health == .unreadable(cause: .notUTF8))
        #expect(!store.documentIsPlaceholder, "a real document must not be relabelled a placeholder")
        #expect(store.items.map(\.text) == ["a real note"])
    }

    /// The other repair shape: a runtime break fixed by rewriting the file
    /// rather than by restoring permissions. That is foreign content, so the
    /// retry adopts it — and the notes typed during the suspension go with it.
    /// The adoption would discard them whenever it landed; the retry only
    /// makes it happen where the user can see it.
    @Test func aRuntimeBreakRepairedByRewritingIsAdoptedByTheRetry() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        _ = store.add(text: "typed after the break")
        store.flush()
        #expect(storage.health == .unreadable(cause: .notUTF8))

        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)
        store.retryUnavailableStorage()

        #expect(storage.health == .ok)
        #expect(store.unavailability == nil)
        #expect(store.items.map(\.text) == ["rewritten by hand"])
    }

    /// An unlink landing while the store is behind must not empty it. A
    /// second read would report the absent file as an empty document — not a
    /// placeholder — and applying that trades the user's notes for the gap,
    /// with `unavailability` then saying input is safe.
    @Test func aRetryDoesNotEmptyTheStoreWhenTheFileIsGone() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()

        // Behind: adopted by the save, delivery not yet arrived.
        try Data("- [ ] rewritten by hand\n".utf8).write(to: url, options: .atomic)
        store.flush()
        #expect(store.unavailability == .adoptionInFlight)

        try FileManager.default.removeItem(at: url)
        store.retryUnavailableStorage()

        #expect(store.items.map(\.text) == ["a real note"], "the notes must survive the file going away")
        #expect(!store.documentIsPlaceholder)
    }

    /// The guard is what keeps the reload off the hot path: it runs on every
    /// panel summon and every capture, and adopting unconditionally would
    /// re-read the file and wipe undo each time.
    @Test func reloadingIsANoOpWhenTheDocumentIsReal() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pewter-store-tests-\(UUID().uuidString)/notes.md")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        let item = try #require(store.add(text: "deletable").item)
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
        _ = store.add(text: "original")
        store.flush()

        try Data("- [ ] edited outside\n".utf8).write(to: url, options: .atomic)
        let deadline = ContinuousClock.now + .seconds(2)
        while store.items.map(\.text) != ["edited outside"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.items.map(\.text) == ["edited outside"])

        // The debounced path every user edit takes.
        _ = store.add(text: "typed after reload")
        try await Task.sleep(for: .milliseconds(300))
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["edited outside", "typed after reload"])

        // And the quit flush.
        _ = store.add(text: "typed before quit")
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
        _ = store.add(text: "typed after rebuild")
        store.flush()
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["outside edit", "typed after rebuild"])
    }
}
