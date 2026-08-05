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
    /// Which generation `document` is on. Handed back on every save so the
    /// storage can refuse one built before an external change it has already
    /// adopted but this store has not applied yet.
    private var generation = FileStorage.DocumentGeneration.initial

    /// True when `document` stands in for notes that could not be read — an
    /// unknown list, not an empty one. Set only at load and cleared once real
    /// content arrives; it never goes back up within a process.
    ///
    /// Distinct from saving being suspended: a file that turns unreadable
    /// while the app runs leaves the real document in memory, so the panel
    /// keeps showing the user's notes and editing them still makes sense.
    /// That says nothing about durability — see `inputWouldBeDiscarded`.
    public private(set) var documentIsPlaceholder = false
    /// Keeps the failed-retry line to once per stretch of unreadability. The
    /// retry runs on every panel summon and every refused input, so a file
    /// left unrepaired would otherwise bury the line explaining why.
    private var loggedFailedReload = false

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

    public init(document: MarkdownDocument = MarkdownDocument()) {
        self.document = document
        storage = nil
    }

    /// Private so `loadFrom` is the only way to pair a store with a storage.
    /// Any other pairing starts the store on the baseline generation; against
    /// a storage that has already adopted an external change, every save the
    /// store makes would then be refused for the life of the process.
    private init(storage: FileStorage) {
        document = MarkdownDocument()
        self.storage = storage
    }

    /// Loads from storage and starts watching for external edits. The handler
    /// is installed before the first load so no change window is missed.
    public static func loadFrom(storage: FileStorage) -> ListStore {
        let store = ListStore(storage: storage)
        storage.setOnExternalChange { [weak store] newDocument, generation in
            // DispatchQueue.main is FIFO; unstructured Tasks are not, and two
            // rapid external edits applied out of order would wedge the UI on
            // stale content (the hash guard suppresses any correction).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store?.applyExternalChange(newDocument, generation: generation)
                }
            }
        }
        let loaded = storage.load()
        store.document = loaded.document
        store.generation = loaded.generation
        store.documentIsPlaceholder = loaded.isPlaceholder
        return store
    }

    /// Replaces the document with an externally-edited one. External wins
    /// over any local edit that raced it — its scheduled save must not fire —
    /// and undo/redo history is cleared: the recorded positions describe a
    /// document that no longer exists.
    ///
    /// No default for `generation`: defaulting to `.initial` is the worst
    /// choice available, since a store left on the baseline while the
    /// storage has moved on has every save refused for the life of the
    /// process.
    func applyExternalChange(
        _ newDocument: MarkdownDocument,
        generation: FileStorage.DocumentGeneration
    ) {
        let before = document.items.count
        let after = newDocument.items.count
        Logger.storage
            .info("external edit replaced the document: \(before) → \(after) notes; undo/redo history cleared")
        document = newDocument
        documentIsPlaceholder = false
        deletedBatches.removeAll()
        redoBatches.removeAll()
        self.generation = generation
    }

    /// True when a note accepted now would not reach disk: the document
    /// isn't the user's notes, or saving is suspended and anything accepted
    /// dies at quit.
    ///
    /// `.saveFailed` is excluded deliberately, not by omission: an unreadable
    /// file will refuse every save until it is repaired, whereas a failed
    /// write is often transient (a full disk that drains, a volume that
    /// remounts) and the next debounce may well land. Refusing captures on it
    /// would trade a rare lie for a common one.
    ///
    /// Broader than `documentIsPlaceholder`, and the right test for a surface
    /// that reports success — capture fires with the panel closed, where an
    /// affirmative "Captured" is the only signal the user gets. The composer
    /// still uses the narrower flag, which is not yet right, and the gap is
    /// wider than a timing window: it misses the first note after a runtime
    /// break (health flips only once the debounced write fails) *and* the
    /// whole in-flight-adoption state, which no banner can ever show because
    /// health there is `.ok`. Switching it needs an observable health mirror —
    /// pw-d0a.
    public var inputWouldBeDiscarded: Bool {
        guard let storage else { return documentIsPlaceholder }
        // The generation check is what covers a retry that recovered by
        // adopting: the file reads fine and health is `.ok`, but the adopted
        // document has not been delivered here yet and will replace anything
        // accepted in the meantime.
        return documentIsPlaceholder
            || storage.health == .unreadable
            || !storage.accepts(generation)
    }

    /// Re-reads the file and takes it up if it has become readable.
    ///
    /// Covers what the watcher misses: it recovers repairs that change the
    /// file's bytes, but not a permission-only fix, and it may never have
    /// armed at all. Nothing else re-reads the file either, since every input
    /// is refused while the document is a placeholder.
    public func reloadIfPlaceholder() {
        guard documentIsPlaceholder, let storage else { return }
        let loaded = storage.load()
        guard !loaded.isPlaceholder else {
            // The user retried to find out whether their repair worked; a
            // silent no-op looks identical to a stale banner.
            if !loggedFailedReload {
                loggedFailedReload = true
                Self.logger.notice("retried the notes file; still unreadable")
            }
            return
        }
        loggedFailedReload = false
        Self.logger.notice("notes file readable again on retry; adopting it")
        // A repaired file is an external change like any other: same
        // adoption, same history reset.
        applyExternalChange(loaded.document, generation: loaded.generation)
    }

    /// Retries whichever repair the current state needs, for surfaces that
    /// must decide right now whether input would be discarded.
    ///
    /// A placeholder re-reads the file. A document that was real when the file
    /// broke must not: re-reading would trade every note added since the break
    /// for what's on disk. That holds only for a repair restoring content the
    /// storage has already seen — a permission fix. A repair that *rewrites*
    /// the file is a foreign change and is adopted like any other, so notes
    /// added during the suspension are lost either way; this only moves that
    /// where the user can see it. Reconciling against the disk covers both
    /// — it clears a suspension the app can no longer justify, and it *raises*
    /// one the app hasn't noticed yet, which health alone can't do since a mode
    /// change fires no watcher event. Unconditional for that second reason:
    /// gating on `health == .unreadable` would let the first capture after a
    /// break report success. Synchronous, so health is current on return.
    public func retryUnavailableStorage() {
        if documentIsPlaceholder {
            reloadIfPlaceholder()
        } else {
            storage?.refreshFromDisk()
        }
    }

    /// Refused on a placeholder document: the note would be dropped when the
    /// real content arrives. Surfaces check first because only they can name
    /// the reason; this is the backstop for one that forgets, and it has to be
    /// loud — a bare nil reads as "nothing to add" downstream.
    @discardableResult
    public func add(text: String) -> Item? {
        guard !documentIsPlaceholder else {
            assertionFailure("add() on a placeholder document; the calling surface must refuse and explain")
            Self.logger.error("add refused: the document is a placeholder")
            return nil
        }
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
        // Committing an editor untouched is not a mutation — it must not
        // fork history or schedule a save.
        guard updated.text != item.text else { return }
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

    /// True when the document in memory is not on disk and no later save will
    /// put it there: storage is unhealthy, or an adopted document is still in
    /// flight and will replace this one on delivery. Sample it after a save.
    /// False without storage — a detached store has nothing to lose.
    ///
    /// `.saveFailed` counts here though `inputWouldBeDiscarded` excludes it:
    /// that exclusion rests on a later debounce landing, and at quit there is
    /// no later debounce.
    var documentDidNotReachDisk: Bool {
        guard let storage else { return false }
        return storage.health != .ok || !storage.accepts(generation)
    }

    /// Saves immediately, reporting whether anything was left unsaved.
    ///
    /// Returning the answer is what keeps it honest: a caller cannot sample it
    /// before the save, where a suspension this very call resolves reads as
    /// loss and an adoption it triggers reads as success.
    @discardableResult
    public func flush() -> Bool {
        storage?.saveNow(document, generation: generation)
        let unsaved = documentDidNotReachDisk
        guard unsaved else { return false }
        // The write path logs suspensions only on the transition, long past by
        // now, so without this the notes added during one die here leaving no
        // trace, at the one moment a diagnostics report most needs it. Bound
        // outside the interpolation: the log closure would need an explicit
        // `self` that swiftformat then strips back out.
        let held = items.count
        Self.logger.error(
            "quitting without a durable save; the file does not have the current \(held, privacy: .public) notes"
        )
        return true
    }

    private func persist() {
        storage?.scheduleSave(document, generation: generation)
    }
}
