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

        store.toggleDone(id: item.id)
        #expect(store.items[0].done == true)
        store.toggleDone(id: item.id)
        #expect(store.items[0].done == false)

        store.delete(id: item.id)
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
}
