import Foundation
import Observation

@MainActor
@Observable
public final class ListStore {
    public private(set) var document: MarkdownDocument
    private let storage: FileStorage?

    private var deletedBatches: [[MarkdownDocument.RemovedItem]] = []
    private static let undoDepth = 10

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
        storage.setOnExternalChange { [weak store] newDocument in
            // DispatchQueue.main is FIFO; unstructured Tasks are not, and two
            // rapid external edits applied out of order would wedge the UI on
            // stale content (the hash guard suppresses any correction).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store?.applyExternalChange(newDocument)
                }
            }
        }
        store.document = storage.load()
        return store
    }

    /// Replaces the document with an externally-edited one. External wins
    /// over any local edit that raced it — its scheduled save must not fire —
    /// and undo history is cleared: the recorded positions describe a
    /// document that no longer exists.
    public func applyExternalChange(_ newDocument: MarkdownDocument) {
        storage?.cancelPendingSave()
        document = newDocument
        deletedBatches.removeAll()
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
        guard !updated.text.isEmpty else {
            // Clearing the text is a delete, and an undoable one.
            delete(ids: [id])
            return
        }
        document.update(updated)
        persist()
    }

    public func delete(ids: Set<UUID>) {
        let removed = document.removeAll(ids: ids)
        guard !removed.isEmpty else { return }
        deletedBatches.append(removed)
        if deletedBatches.count > Self.undoDepth {
            deletedBatches.removeFirst()
        }
        persist()
    }

    /// Restores the most recent deleted batch and returns the restored items,
    /// empty when there is nothing to undo. Recorded indices are always
    /// valid: `lines` shrinks only through `delete(ids:)` (which always
    /// records) or `applyExternalChange` (which clears the history), later
    /// adds only append, and the depth cap evicts from the oldest end.
    public func undoDelete() -> [Item] {
        guard let batch = deletedBatches.popLast() else { return [] }
        // Ascending re-insert mirrors how the removals shifted later lines,
        // so positions and interleaved verbatim lines come back exactly.
        for entry in batch {
            document.insert(entry.item, at: entry.index)
        }
        persist()
        return batch.map(\.item)
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
