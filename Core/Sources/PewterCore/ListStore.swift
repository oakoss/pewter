import Foundation
import Observation

@MainActor
@Observable
public final class ListStore {
    public private(set) var document: MarkdownDocument
    private let storage: FileStorage?

    public var items: [Item] {
        document.items
    }

    public init(document: MarkdownDocument = MarkdownDocument(), storage: FileStorage? = nil) {
        self.document = document
        self.storage = storage
    }

    /// Loads from storage and starts watching for external edits. The handler
    /// is installed before the first load so no change window is missed.
    public static func loadFrom(storage: FileStorage) -> ListStore {
        let store = ListStore(storage: storage)
        storage.setOnExternalChange { [weak store, weak storage] newDocument in
            // DispatchQueue.main is FIFO; unstructured Tasks are not, and two
            // rapid external edits applied out of order would wedge the UI on
            // stale content (the hash guard suppresses any correction).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // External wins over any local edit that raced this
                    // application; its scheduled save must not fire.
                    storage?.cancelPendingSave()
                    store?.document = newDocument
                }
            }
        }
        store.document = storage.load()
        return store
    }

    @discardableResult
    public func add(text: String) -> Item? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = Item(text: trimmed)
        document.append(item)
        persist()
        return item
    }

    public func updateText(id: UUID, text: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        // Rebuilding through the initializer applies its line-break
        // normalization to edited text, same as captured text.
        let updated = Item(id: item.id, text: text, done: item.done, createdAt: item.createdAt)
        if updated.text.isEmpty {
            document.removeAll(ids: [id])
        } else {
            document.update(updated)
        }
        persist()
    }

    public func delete(ids: Set<UUID>) {
        if document.removeAll(ids: ids) {
            persist()
        }
    }

    public func setDone(ids: Set<UUID>, done: Bool) {
        if document.setDone(ids: ids, done: done) {
            persist()
        }
    }

    /// True when every item in `ids` is done. Drives both the converge
    /// direction and the context-menu label, so the two can't disagree.
    public func allDone(ids: Set<UUID>) -> Bool {
        items.filter { ids.contains($0.id) }.allSatisfy(\.done)
    }

    /// Converges a mixed selection instead of flipping each member: any
    /// not-done item marks the whole set done.
    public func toggleDone(ids: Set<UUID>) {
        setDone(ids: ids, done: !allDone(ids: ids))
    }

    public func filtered(query: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public func flush() {
        storage?.saveNow(document)
    }

    private func persist() {
        storage?.scheduleSave(document)
    }
}
