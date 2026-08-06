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

    /// Why `document` stands in for notes that could not be read — an unknown
    /// list, not an empty one. Set only at load and cleared once real content
    /// arrives; it never goes back up within a process.
    ///
    /// Distinct from saving being suspended: a file that turns unreadable
    /// while the app runs leaves the real document in memory, so the panel
    /// keeps showing the user's notes and editing them still makes sense.
    /// That says nothing about durability — see `unavailability`.
    public private(set) var placeholderCause: UnreadableCause?

    /// True when the list on screen is not the user's notes. The narrow test,
    /// for surfaces describing the *document* — the empty state and the
    /// composer's placeholder text. A surface reporting whether input will be
    /// kept wants `unavailability`, which is broader.
    public var documentIsPlaceholder: Bool {
        placeholderCause != nil
    }

    /// Storage health, mirrored here so SwiftUI can observe it: `FileStorage`
    /// is not `@Observable`, and a view bound to its `health` would render
    /// once and then stick.
    ///
    /// Deliberately not public: this can be a main-queue hop behind, and a
    /// decision branched on a stale value is exactly the "Captured" that
    /// wasn't. `unavailability` is the public way to ask, and it reads the
    /// storage directly. Re-sampled synchronously wherever the store pokes the
    /// storage itself, so a panel that summons, retries and draws in one turn
    /// shows the banner that retry earned rather than the previous one.
    private(set) var health = FileStorage.Health.ok

    /// Banner text for a storage problem worth interrupting the user about,
    /// nil when there is none.
    ///
    /// Only `health` feeds it. The other two refusal states are deliberately
    /// toast-only: an in-flight adoption clears itself within a turn, so a
    /// banner for it would flicker and name no action, and a placeholder
    /// already says so through the empty state and the composer's prompt.
    public var storageBanner: String? {
        health.bannerMessage
    }

    /// The cause the last failed-retry line named, so the line appears once
    /// per distinct failure rather than once per retry. The retry runs on
    /// every panel summon and every refused input, so a file left unrepaired
    /// would otherwise bury the line explaining why — but a file whose failure
    /// mode *changed* has something new to say.
    private var lastLoggedReloadFailure: UnreadableCause?

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

    /// Loads from storage and starts watching for external edits. The
    /// external-change handler is installed before the first load so no change
    /// window is missed.
    ///
    /// Health is registered *after*, deliberately: registration delivers the
    /// current value, so wiring it first would queue the pre-load `.ok` behind
    /// the load's own verdict and land it second, clearing a banner over a
    /// file that cannot be read. Nothing is missed by waiting — the
    /// registration runs on the storage's queue, so a change is either folded
    /// into that initial value or delivered after it.
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
        // Both from the load's own verdict, so they describe one read.
        // Seeded rather than left to the first delivery: that delivery is a
        // main-queue hop away, and a panel drawn in between would show no
        // banner over a file the load already found broken.
        store.placeholderCause = loaded.health.unreadableCause
        store.health = loaded.health
        storage.setOnHealthChange { [weak store, weak storage] _ in
            // The delivered value is discarded and the storage re-read: this
            // hop is a ping that something changed, not the answer. A value
            // captured at send time can be older than a synchronous sample a
            // retry has already taken, and assigning it would re-raise a
            // banner that retry had cleared until the next delivery landed.
            // Re-reading on arrival is always the newest answer.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let storage else { return }
                    store?.health = storage.health
                }
            }
        }
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
        // A reload supersedes whatever was in flight when it ran, so a
        // delivery on a generation this store has already applied describes an
        // older document — applying it would discard everything added since,
        // including the capture that prompted the reload.
        if generation <= self.generation {
            Logger.storage.notice("dropped an external delivery the store has already moved past")
            return
        }
        let before = document.items.count
        let after = newDocument.items.count
        Logger.storage
            .info("external edit replaced the document: \(before) → \(after) notes; undo/redo history cleared")
        document = newDocument
        placeholderCause = nil
        deletedBatches.removeAll()
        redoBatches.removeAll()
        self.generation = generation
    }

    /// Why a note accepted now would not reach disk, or nil when it would.
    /// The right test for any surface that reports whether input was kept; see
    /// `Unavailability` for why the reason travels.
    ///
    /// `.saveFailed` is excluded deliberately, not by omission: an unreadable
    /// file will refuse every save until it is repaired, whereas a failed
    /// write is often transient (a full disk that drains, a volume that
    /// remounts) and the next debounce may well land. Refusing captures on it
    /// would trade a rare lie for a common one.
    public var unavailability: Unavailability? {
        // A detached store has no file to lose a note to. It can't hold a
        // placeholder either — only the two storage-backed paths set one.
        guard let storage else { return nil }
        // The storage rather than the `health` mirror: a save or a retry that
        // has discovered a break has its notification queued behind this
        // caller, and the mirror would report the state it disproved. One
        // hop, not two — an adoption landing between separate reads is missed.
        let status = storage.status(for: generation)
        // Ordered by which remedy outranks which, not by which flag is
        // cheapest. An unreadable file is a repair to go and make and outlasts
        // everything else, so it wins wherever it holds.
        if let cause = status.health.unreadableCause {
            return .unreadable(cause: cause)
        }
        // Then the handoff window: the file reads fine, health is `.ok`, and
        // an adopted document has not been delivered here yet. This
        // sits above `placeholderCause` because a *recovering* placeholder
        // passes through exactly this state — health clears one main-queue
        // turn before the adoption that clears the placeholder lands, and
        // naming the old cause there tells a user who has already repaired
        // their file to go and repair it again.
        guard status.accepts else { return .adoptionInFlight }
        // A placeholder with healthy storage and nothing in flight: reachable
        // when the unreadable file is deleted outright, which resumes saving
        // without ever handing this store real content.
        return placeholderCause.map { .unreadable(cause: $0) }
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
        // Taken from the load rather than re-read, so one look at the file
        // feeds both the mirror and the placeholder: a second `queue.sync`
        // could catch a watcher event in between and leave the banner
        // describing a different read than the refusal does. Set synchronously
        // because the storage's own notification is a main-queue hop behind
        // this caller, and a panel about to draw would keep the banner this
        // load cleared — or miss the one it raised.
        health = loaded.health
        if let cause = loaded.health.unreadableCause {
            // A repair can change the failure mode instead of fixing it — a
            // UTF-16 re-save of a file that was unreadable for permissions —
            // and every surface names the cause, so the new one is taken up
            // even though the document stays a placeholder.
            placeholderCause = cause
            // `load()` minted a generation whether or not it could read the
            // file. Not taking it strands this store behind the storage for
            // good, with nothing in flight to catch up to — and the refusal
            // that produces is `.adoptionInFlight`, whose whole remedy is
            // "try again", which would never work.
            generation = loaded.generation
            // The user retried to find out whether their repair worked; a
            // silent no-op looks identical to a stale banner. Keyed on the
            // cause rather than on having logged at all: a permission fix that
            // re-saves as UTF-16 is a new failure, and suppressing it leaves
            // the log naming the repair the user already made.
            if lastLoggedReloadFailure != cause {
                lastLoggedReloadFailure = cause
                let reason = cause.logDescription
                Self.logger.notice("retried the notes file; still unreadable (\(reason))")
            }
            return
        }
        lastLoggedReloadFailure = nil
        // "Readable" covers a file that is gone, too: the load reports an
        // absent file as an empty document, and adopting it is how a deletion
        // reaches the store. Saying "adopting what is on disk" keeps the line
        // true in both cases; the storage logs which one it was.
        Self.logger.notice("notes file re-read on retry; adopting what is on disk")
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
    /// break report success.
    ///
    /// Synchronous, so health *and the document* are current on return: both
    /// are taken from the refresh rather than awaited, and an adoption found
    /// here is applied, which replaces the document and clears undo history. A
    /// panel summon can therefore swap the list out before it draws.
    public func retryUnavailableStorage() {
        if documentIsPlaceholder {
            reloadIfPlaceholder()
            return
        }
        guard let storage else { return }
        let refresh = storage.refreshFromDisk()
        // Taken here rather than left to the change handler, which is queued
        // a hop behind and would miss the window this refresh closed.
        health = refresh.health
        // Reconciling can adopt, which leaves this store behind until the
        // delivery arrives on the next main-queue turn — and a surface asking
        // in between refuses, naming a file that reads perfectly. Taking the
        // adoption here instead lets the capture land on it. The delivery
        // still in flight carries this same generation, so it is dropped
        // rather than applied twice.
        //
        // A store left behind by an *earlier* adoption is not covered: there
        // is nothing to hand back, and re-reading to catch up would race an
        // unlink into replacing the document with an empty one. That window
        // closes by itself when the delivery lands on the next turn, and until
        // it does `unavailability` reports `.adoptionInFlight`, whose remedy
        // is to try again rather than to go and repair a healthy file.
        guard let adopted = refresh.adopted else { return }
        applyExternalChange(adopted.document, generation: adopted.generation)
    }

    /// What became of an add. An optional conflated the two ways it can fail —
    /// nothing to add is about the input, a refusal is about the file — so
    /// callers switch rather than inferring a remedy from an absence.
    public enum AddResult: Equatable, Sendable {
        case added(Item)
        /// Whitespace-only text; nothing was stored and nothing is wrong.
        case emptyText
        /// The text was fine but would not have reached disk.
        case refused(Unavailability)
    }

    /// Appends `text`, refusing when it would not reach disk rather than
    /// accepting it into a document that is about to be replaced.
    ///
    /// The refusal lives here, not in each surface, so a caller cannot forget
    /// it and silently drop the user's text. It covers this method only —
    /// every other mutation still persists unchecked (pw-jvu).
    ///
    /// Callers that can retry should call `retryUnavailableStorage()` first;
    /// this does not, because the retry can replace the document out from
    /// under a surface that is mid-render.
    ///
    /// Not `@discardableResult`: dropping the answer is how the user's text
    /// goes missing without anyone being told, which is the whole failure this
    /// return type exists to make impossible.
    public func add(text: String) -> AddResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }
        // After the empty check: whitespace-only text has nothing to lose, and
        // reporting a file problem for it names a remedy that would not have
        // helped.
        if let unavailability {
            Self.logger.error("add refused: \(unavailability.logDescription, privacy: .public)")
            return .refused(unavailability)
        }
        let item = Item(text: trimmed)
        document.append(item)
        invalidateRedo()
        persist()
        return .added(item)
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
    /// `.saveFailed` counts here though `unavailability` excludes it:
    /// that exclusion rests on a later debounce landing, and at quit there is
    /// no later debounce.
    var documentDidNotReachDisk: Bool {
        guard let storage else { return false }
        // One hop for the same reason as `unavailability`, and it matters more
        // here: this is the quit path, where a missed break is the last chance
        // to say so rather than something the next debounce retries.
        let status = storage.status(for: generation)
        return status.health != .ok || !status.accepts
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
