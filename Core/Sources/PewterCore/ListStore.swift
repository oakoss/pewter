import Foundation
import Observation
import os

@MainActor
@Observable
public final class ListStore {
    /// Note-lifecycle breadcrumbs — counts only, never content. "Where did
    /// my note go" reports hinge on these; benign high-frequency actions
    /// (toggle done, edits) stay silent so they can't push the interesting
    /// lines out of the diagnostics window.
    private static let logger = Logger.panel

    public private(set) var document: MarkdownDocument
    private let storage: FileStorage?

    /// One undoable mutation: the lines it removed, plus any line it
    /// inserted (merge), each with its recorded index. Undo removes the
    /// inserted lines first, then re-inserts the removals; redo replays
    /// the mutation from the same records in the opposite order.
    private struct UndoBatch {
        var removed: [MarkdownDocument.RemovedItem]
        var inserted: [MarkdownDocument.RemovedItem] = []
    }

    private var deletedBatches: [UndoBatch] = []
    private var redoBatches: [UndoBatch] = []
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
    /// and undo/redo history is cleared: the recorded positions describe a
    /// document that no longer exists.
    public func applyExternalChange(_ newDocument: MarkdownDocument) {
        storage?.cancelPendingSave()
        let before = document.items.count
        let after = newDocument.items.count
        Logger.storage
            .info("external edit replaced the document: \(before) → \(after) notes; undo/redo history cleared")
        document = newDocument
        deletedBatches.removeAll()
        redoBatches.removeAll()
    }

    @discardableResult
    public func add(text: String) -> Item? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = Item(text: trimmed)
        document.append(item)
        invalidateRedo()
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
        invalidateRedo()
        persist()
    }

    public func delete(ids: Set<UUID>) {
        let removed = document.removeAll(ids: ids)
        guard !removed.isEmpty else { return }
        Self.logger.info("deleted \(removed.count) notes")
        recordUndo(UndoBatch(removed: removed))
        invalidateRedo()
        persist()
    }

    /// Merges the given items into one note at the earliest one's position,
    /// joining texts in document order — selection order must not matter.
    /// Blank-line separator so merged notes stay readable paragraphs;
    /// document order over createdAt is deliberate — a hand-reordered file
    /// wins. The merged
    /// note keeps the first item's identity and is done only when every
    /// source was done. Undoable as a single batch.
    @discardableResult
    public func merge(ids: Set<UUID>) -> Item? {
        let sources = items.filter { ids.contains($0.id) }
        guard sources.count >= 2, let first = sources.first else { return nil }
        let merged = Item(
            id: first.id,
            text: sources.map(\.text).joined(separator: "\n\n"),
            done: sources.allSatisfy(\.done),
            createdAt: first.createdAt
        )
        let removed = document.removeAll(ids: ids)
        guard let index = removed.first?.index else { return nil }
        document.insert(merged, at: index)
        Self.logger.info("merged \(sources.count) notes into one")
        recordUndo(UndoBatch(
            removed: removed,
            inserted: [MarkdownDocument.RemovedItem(index: index, item: merged)]
        ))
        invalidateRedo()
        persist()
        return merged
    }

    private func recordUndo(_ batch: UndoBatch) {
        deletedBatches.append(batch)
        if deletedBatches.count > Self.undoDepth {
            deletedBatches.removeFirst()
        }
    }

    /// Every fresh mutation forks history: the redo batches describe a
    /// timeline the user has now diverged from, and replaying one against
    /// the new document could target wrong lines.
    private func invalidateRedo() {
        redoBatches.removeAll()
    }

    /// Restores the most recent batch and returns the restored items, empty
    /// when there is nothing to undo. Recorded indices are always valid:
    /// `lines` shrinks only through `delete(ids:)` and `merge(ids:)` (which
    /// always record), `applyExternalChange` (which clears the history), or
    /// `redo()` (which replays a batch against the exact state it was
    /// recorded from and re-records it); later adds only append, LIFO undo
    /// replays states in reverse, and the depth cap evicts from the oldest
    /// end. Removing a merge's inserted line first restores the exact line
    /// count its indices were recorded against.
    public func undoDelete() -> [Item] {
        guard let batch = deletedBatches.popLast() else { return [] }
        Self.logger.info("undo restored \(batch.removed.count) notes")
        if !batch.inserted.isEmpty {
            _ = document.removeAll(ids: Set(batch.inserted.map(\.item.id)))
        }
        // Ascending re-insert mirrors how the removals shifted later lines,
        // so positions and interleaved verbatim lines come back exactly.
        for entry in batch.removed {
            document.insert(entry.item, at: entry.index)
        }
        redoBatches.append(batch)
        persist()
        return batch.removed.map(\.item)
    }

    /// Outcome of a successful redo: what vanished again and, for a merge,
    /// the product it re-created.
    public struct RedoResult: Equatable, Sendable {
        public let removed: [Item]
        public let mergedProduct: Item?
    }

    /// Re-applies the most recently undone batch; nil when there is nothing
    /// to redo. Valid by construction: only `undoDelete` feeds the redo
    /// stack, every other mutation clears it, and external changes clear
    /// both stacks — so at redo time the document is byte-for-byte the
    /// state the batch was recorded against.
    public func redo() -> RedoResult? {
        guard let batch = redoBatches.popLast() else { return nil }
        Self.logger.info("redo re-removed \(batch.removed.count) notes")
        _ = document.removeAll(ids: Set(batch.removed.map(\.item.id)))
        for entry in batch.inserted {
            document.insert(entry.item, at: entry.index)
        }
        // Back onto the undo stack, so Cmd-Z can reverse the redo again.
        recordUndo(batch)
        persist()
        return RedoResult(
            removed: batch.removed.map(\.item),
            mergedProduct: batch.inserted.first?.item
        )
    }

    public func setDone(ids: Set<UUID>, done: Bool) {
        if document.setDone(ids: ids, done: done) {
            invalidateRedo()
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

    /// Sections narrowed to `query`. A section whose heading matches is
    /// returned whole — the match is the group itself, and hiding notes under
    /// a matched header would make search miss text visible on screen.
    /// Otherwise a section keeps only its matching items, and drops entirely
    /// when nothing matches. An empty query returns every section, empty
    /// ones included.
    public func sections(matching query: String) -> [MarkdownDocument.Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let sections = document.sections
        guard !trimmed.isEmpty else { return sections }
        return sections.compactMap { section in
            if let heading = section.heading, Self.matches(heading, trimmed) {
                return section
            }
            let matches = section.items.filter { Self.matches($0.text, trimmed) }
            guard !matches.isEmpty else { return nil }
            return MarkdownDocument.Section(id: section.id, heading: section.heading, items: matches)
        }
    }

    private static func matches(_ text: String, _ trimmedQuery: String) -> Bool {
        text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public func flush() {
        storage?.saveNow(document)
    }

    private func persist() {
        storage?.scheduleSave(document)
    }
}
