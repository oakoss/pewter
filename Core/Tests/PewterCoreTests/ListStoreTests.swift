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

        let reloaded = FileStorage(fileURL: url).load()
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

    @Test func filterIsCaseAndDiacriticInsensitive() {
        let store = ListStore()
        store.add(text: "Café notes")
        store.add(text: "unrelated")

        #expect(store.filtered(query: "cafe").count == 1)
        #expect(store.filtered(query: "CAFÉ").count == 1)
        #expect(store.filtered(query: "").count == 2)
        #expect(store.filtered(query: "zzz").isEmpty)
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
        #expect(store.document.lines.first == .verbatim("## Heading"))
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

        let reloaded = FileStorage(fileURL: url).load()
        #expect(reloaded.items.map(\.text) == ["keep me"])
    }

    @Test func applyExternalChangeClearsUndoHistory() throws {
        let store = ListStore()
        let item = try #require(store.add(text: "deleted in app"))
        store.delete(ids: [item.id])

        store.applyExternalChange(MarkdownDocument.parse("- [ ] rewritten outside\n"))
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
}
