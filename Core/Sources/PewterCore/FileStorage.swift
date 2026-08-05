import CryptoKit
import Foundation
import os

/// Owns the notes file: debounced atomic writes, and a file watcher that
/// reloads on external edits while ignoring our own saves.
public final class FileStorage: @unchecked Sendable {
    public let fileURL: URL

    public enum Health: Equatable, Sendable {
        case ok
        case saveFailed(reason: String)
        /// The notes file exists but can't be read; saves are suspended so
        /// the app can never overwrite content it hasn't seen.
        case unreadable
    }

    /// Which document a save is built on. The storage hands one out with
    /// every external change it adopts and every load, and takes it back on
    /// every save, so a save that predates either is refused rather than
    /// trusted.
    ///
    /// Only this file can mint one, so a caller cannot fabricate a newer
    /// generation to get a stale save accepted. `.initial` can be named
    /// module-wide, which is safe for the same reason: these only ever move
    /// forward, so the baseline matches exactly once — before the first
    /// delivery or load, which is when claiming it is true. Rewinding the
    /// counter anywhere would break that and let one value be minted twice.
    public struct DocumentGeneration: Equatable, Comparable, Sendable {
        fileprivate let value: UInt64

        /// Ordering is what lets a receiver drop a delivery it has already
        /// moved past. Equality cannot tell a lower generation from a higher
        /// one, and a delivery in flight when a load superseded it carries
        /// exactly that.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.value < rhs.value
        }

        /// Before any external change: what a freshly loaded document is on.
        static let initial = DocumentGeneration(value: 0)

        fileprivate var next: DocumentGeneration {
            DocumentGeneration(value: value + 1)
        }
    }

    public static let defaultDebounceInterval: TimeInterval = 0.5

    private let logger = Logger.storage
    private let queue = DispatchQueue(label: "com.oakoss.Pewter.storage")
    // Callbacks are delivered on this separate serial queue so they never run
    // while `queue` is held — a handler that synchronously calls back into
    // this class (e.g. health) would otherwise deadlock. Serial, so
    // FIFO ordering across all events is preserved.
    private let eventQueue = DispatchQueue(label: "com.oakoss.Pewter.storage-events")
    private let debounceInterval: TimeInterval
    private let watchesExternalChanges: Bool
    private var onExternalChange: (@Sendable (MarkdownDocument, DocumentGeneration) -> Void)?
    private var onHealthChange: (@Sendable (Health) -> Void)?
    private var pendingSave: DispatchWorkItem?
    /// Digest of the bytes the storage believes are on disk — its own last
    /// write, or content it adopted from an external edit. `nil` means it
    /// holds no belief, so anything on disk is content it has never seen.
    private var lastKnownDiskHash: SHA256Digest?
    /// Generation the storage last handed out. `write()` refuses a save built
    /// on an earlier one, since the handoff to the store is asynchronous and
    /// it may not have applied yet.
    private var currentGeneration = DocumentGeneration.initial
    /// Keeps the detached-storage diagnostic to once per stretch of
    /// detachment rather than once per refused save.
    private var loggedDetachedAdoption = false
    /// True while a save is being refused, so the reason is logged on the
    /// transition instead of on every debounce tick — sustained typing would
    /// otherwise evict the line that explains the cause.
    private var loggedRefusedSave = false
    private var watcher: DispatchSourceFileSystemObject?
    private var currentHealth: Health = .ok

    public convenience init(
        fileURL: URL,
        debounceInterval: TimeInterval = FileStorage.defaultDebounceInterval
    ) {
        self.init(fileURL: fileURL, debounceInterval: debounceInterval, watchesExternalChanges: true)
    }

    private init(fileURL: URL, debounceInterval: TimeInterval, watchesExternalChanges: Bool) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
        self.watchesExternalChanges = watchesExternalChanges
    }

    /// A storage whose watcher never arms — the state production reaches on
    /// its own when neither watch arm can be armed (see `rewatch`). Staging
    /// it deterministically is what lets a test exercise an external edit the
    /// app was never told about; with a live watcher its own adoption wins
    /// the race and the pre-write check never runs.
    static func unwatched(
        fileURL: URL,
        debounceInterval: TimeInterval = defaultDebounceInterval
    ) -> FileStorage {
        FileStorage(
            fileURL: fileURL,
            debounceInterval: debounceInterval,
            watchesExternalChanges: false
        )
    }

    deinit {
        watcher?.cancel()
    }

    public static func defaultURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Pewter/pewter.md")
    }

    /// Current storage health. `.unreadable` overrides a save failure, and
    /// recovering from it resets straight to `.ok` rather than restoring a
    /// prior `.saveFailed` — if the underlying problem persists, the next
    /// save simply re-reports it. A bare `.saveFailed` only clears when a
    /// save succeeds; a working external read says nothing about whether
    /// writes work again.
    ///
    /// Covers reading and writing the file, not watching it: a failure to
    /// arm the watcher leaves this untouched and is log-only (see `rewatch`).
    public var health: Health {
        queue.sync { currentHealth }
    }

    /// Brings health and, where needed, the adopted document back in line with
    /// what is actually on disk. Returns whether writing is safe.
    ///
    /// Split out of `write` so a surface that must decide *before* accepting
    /// input can ask the same question without writing. Health alone is not an
    /// answer: a mode change fires no watcher event, so it can still read `.ok`
    /// about a file that has already broken, and the first capture after that
    /// would be reported as saved.
    @discardableResult
    private func reconcileWithDisk(noticedAt context: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        switch inspectOnDisk() {
        case .absent, .ours:
            resumeSavesIfSuspended()
            return true
        case let .unreadable(reason):
            // Same protection as at load: never overwrite content the app
            // can't read, so can't have seen. Re-arm on the way out — landing
            // here at all is evidence the watcher missed the change that
            // broke the file, and without a watcher nothing else re-reads it.
            // Logged on the transition: unlike an adoption this neither bumps
            // the generation nor changes the hash, so every later save
            // re-enters and would repeat the line for as long as it lasts.
            if currentHealth != .unreadable {
                logger
                    .error(
                        "notes file is unreadable \(context, privacy: .public) (\(reason)); suspending saves to protect it"
                    )
            }
            rewatch()
            setHealth(.unreadable)
            return false
        case let .foreign(text, hash):
            resumeSavesIfSuspended()
            logger.warning("notes file changed on disk with no watcher event; adopting it rather than overwriting")
            rewatch()
            adoptExternalContent(MarkdownDocument.parse(text), hash: hash)
            return false
        }
    }

    /// Re-reads the file's state without writing, so a caller can find out
    /// whether input accepted right now would survive.
    func refreshFromDisk() {
        queue.sync { _ = reconcileWithDisk(noticedAt: "on retry") }
    }

    /// True when a document built on `generation` can still be saved.
    ///
    /// A store behind this storage has an adopted document already in flight
    /// to it, and applying that delivery replaces whatever the store is
    /// holding. Health says nothing about this — the file can be perfectly
    /// readable — so a surface that reports success needs to ask separately.
    func accepts(_ generation: DocumentGeneration) -> Bool {
        queue.sync { generation == currentGeneration }
    }

    /// Sets the handler called with the freshly parsed document when the file
    /// changes on disk from outside the app, and the generation that document
    /// is on. Invoked on an arbitrary queue. Saving anything built on an
    /// earlier generation is refused, so the handler must keep the one it was
    /// given and hand it back on every later save.
    public func setOnExternalChange(
        _ handler: @escaping @Sendable (MarkdownDocument, DocumentGeneration) -> Void
    ) {
        queue.sync { onExternalChange = handler }
    }

    /// Invoked on an arbitrary queue with the current value once at
    /// registration, then with the new value whenever `health` changes —
    /// no separate initial read is needed, and nothing can slip between
    /// the read and the wiring. Equal values coalesce after that first
    /// delivery, so a surface cleared independently of this handler
    /// (e.g. a dismissed banner) won't reappear on a repeat of the same
    /// failure.
    public func setOnHealthChange(_ handler: @escaping @Sendable (Health) -> Void) {
        queue.sync {
            onHealthChange = handler
            let current = currentHealth
            eventQueue.async { handler(current) }
        }
    }

    // MARK: - Load / save

    /// Reads the file and mints a fresh generation for what it read, so a
    /// store built from it starts level with the storage rather than behind
    /// it. A store that started behind could never catch up: the known hash
    /// suppresses further deliveries, and a refused save returns before it
    /// would adopt anything.
    ///
    /// Minting rather than handing back what it found is what lets the caller
    /// outrank a delivery still in flight: both would otherwise hold the same
    /// value, and the late one would win on arrival.
    ///
    /// Rewinding to the baseline here would be the same repair, but
    /// generations only move forward: a stale holder of the earlier value
    /// would then compare equal and overwrite content nothing had applied.
    ///
    /// The read runs on the queue, so a watcher event can't adopt between
    /// reading the bytes and recording them and leave the newer hash and
    /// generation overwritten by this older snapshot.
    ///
    /// `isPlaceholder` reports whether the returned document stands in for
    /// notes that couldn't be read. It is decided inside the same hop that
    /// reads the file: asking afterwards would race the watcher this call
    /// arms, and a caller that saw a stale answer would treat an empty
    /// placeholder as the user's real notes.
    ///
    /// The recorded digest is replaced unconditionally, so loading over an
    /// absent or unreadable file clears it rather than leaving one that names
    /// bytes no longer there.
    func load() -> (document: MarkdownDocument, generation: DocumentGeneration, isPlaceholder: Bool) {
        queue.sync {
            var document = MarkdownDocument()
            var loadedHash: SHA256Digest?
            var isUnreadable = false
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) {
                    loadedHash = SHA256.hash(data: data)
                    document = MarkdownDocument.parse(text)
                } else {
                    // The file exists but can't be read (permissions, non-UTF8).
                    // Proceeding with an empty document and live saves would
                    // overwrite the user's data — refuse to write instead.
                    // Throttled like the save path's twin: a summon re-reads,
                    // so an unrepaired file would otherwise log this on every
                    // summon and bury the line that explains it.
                    if currentHealth != .unreadable {
                        logger.error("notes file exists but is unreadable; suspending saves to protect it")
                    }
                    isUnreadable = true
                }
            }
            // Symmetric with the write path: a read that works, or a file
            // that is gone, ends a suspension. Without it a reload that
            // succeeds would leave the banner up over readable notes.
            if isUnreadable {
                setHealth(.unreadable)
            } else {
                resumeSavesIfSuspended()
            }
            lastKnownDiskHash = loadedHash
            // The caller now holds what is on disk; anything queued was built
            // before that and would write over it at a matching generation.
            // Reachable only if a caller loads with edits outstanding, which
            // no surface does today — so say it rather than leave the
            // discarded edit to be inferred from a note that vanished.
            if pendingSave != nil {
                logger.notice("dropped a queued save on load; the caller now holds what is on disk")
            }
            pendingSave?.cancel()
            pendingSave = nil
            rewatch()
            // A read that supersedes: the caller leaves holding the current
            // file, so any delivery still in flight describes a document it
            // has already moved past. Handing back the generation as found
            // would make the two indistinguishable and let the late one win.
            currentGeneration = currentGeneration.next
            return (document, currentGeneration, isUnreadable)
        }
    }

    /// Neither entry point gates on `health`: the write consults the file
    /// itself, which is a stricter test and — unlike a cached health value —
    /// re-evaluates every time, so a repaired file resumes saving on its own.
    public func scheduleSave(_ document: MarkdownDocument, generation: DocumentGeneration) {
        queue.sync {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.write(document, generation: generation)
            }
            pendingSave = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    public func saveNow(_ document: MarkdownDocument, generation: DocumentGeneration) {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            write(document, generation: generation)
        }
    }

    private func write(_ document: MarkdownDocument, generation: DocumentGeneration) {
        guard let data = document.serialized().data(using: .utf8) else {
            assertionFailure("notes document not encodable as UTF-8")
            logger.error("notes document not encodable as UTF-8; save skipped")
            return
        }
        guard generation == currentGeneration else {
            let built = generation.value
            let current = currentGeneration.value
            if built > current {
                // Can't happen without a bug, since generations only rise
                // and only this file mints them. Unthrottled: being rare is
                // the whole signal.
                assertionFailure("save carries a generation this storage never handed out")
                logger.error("save refused: generation \(built) was never handed out (current \(current))")
            } else if !loggedRefusedSave {
                loggedRefusedSave = true
                // The values separate a store one delivery behind, which
                // catches up, from one stranded on a generation that can
                // never match again.
                logger.warning("save refused: built on generation \(built), current is \(current)")
            }
            return
        }
        loggedRefusedSave = false
        guard reconcileWithDisk(noticedAt: "at save time") else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastKnownDiskHash = SHA256.hash(data: data)
            // Atomic writes rename over the file, changing the inode; the
            // watcher's descriptor now points at the old file.
            rewatch()
            setHealth(.ok)
        } catch {
            logger.error("failed to save notes file: \(error.localizedDescription)")
            setHealth(.saveFailed(reason: error.localizedDescription))
        }
    }

    /// What the notes file holds, relative to what the storage believes is
    /// there. Every write consults this instead of trusting that a watcher
    /// event would have arrived: the watcher can go quiet — neither watch arm
    /// arming, latency between an external write and its event, an editor
    /// pattern the event mask doesn't cover — and any of those would
    /// otherwise end with a save atomically overwriting an edit the app never
    /// read, leaving no trace.
    private enum OnDiskState {
        /// No file. A fresh install and a deletion the watcher already
        /// propagated look identical here, so the write proceeds and creates
        /// the file. A deletion the watcher *missed* is therefore the one
        /// case this check does not cover — see pw-px7.
        case absent
        /// The bytes the storage last saw; overwriting them loses nothing.
        case ours
        /// `reason` travels rather than being logged where it is found: the
        /// remedy differs per cause (fix permissions vs re-save as UTF-8) and
        /// the caller logs it once per suspension, not once per refused save.
        case unreadable(reason: String)
        /// Content the storage has never seen, which includes the
        /// never-loaded case where it holds no belief about the file at all.
        case foreign(text: String, hash: SHA256Digest)
    }

    private func inspectOnDisk() -> OnDiskState {
        dispatchPrecondition(condition: .onQueue(queue))
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Absent covers both a fresh install and the file vanishing
            // between this read and any prior existence check; only a file
            // that is present and still unreadable suspends saves.
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
            return .unreadable(reason: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable(reason: "not valid UTF-8")
        }
        let hash = SHA256.hash(data: data)
        return hash == lastKnownDiskHash ? .ours : .foreign(text: text, hash: hash)
    }

    /// Takes what is on disk as the truth and hands it to the store — an
    /// edit, or an empty document for a deletion. External changes win: the
    /// app's copy is always re-derivable from the file, and the reverse
    /// isn't. Dropping the queued save is an optimization rather than the
    /// protection — it carries the superseded generation, so it would be
    /// refused at the write regardless.
    ///
    /// With no store attached, nothing is recorded as seen. Leaving the hash
    /// stale keeps every later write re-inspecting the file and refusing —
    /// protection that re-evaluates rather than latching, so a store wired up
    /// afterwards is still handed the content on the next save.
    private func adoptExternalContent(_ document: MarkdownDocument, hash: SHA256Digest?) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingSave?.cancel()
        pendingSave = nil
        guard let onExternalChange else {
            // A digest may not be recorded as seen when nothing will apply
            // it — the stale one keeps every write re-inspecting and
            // refusing. A deletion is the exception: nil records no belief
            // at all, and keeping a digest for a file that is gone is itself
            // the lie the comparison would act on.
            if hash == nil {
                lastKnownDiskHash = nil
            }
            if !loggedDetachedAdoption {
                loggedDetachedAdoption = true
                logger.error("external change with no store attached; saves are refused until one is wired up")
            }
            return
        }
        loggedDetachedAdoption = false
        lastKnownDiskHash = hash
        // Bumped only where the content is handed over, so a storage with
        // nobody to hand it to leaves the generation alone and keeps
        // re-inspecting an edit, rather than stranding every later save on a
        // generation nothing was told about. A deletion is not covered: it
        // leaves nothing on disk to re-inspect, so the next write recreates
        // the file (pw-px7).
        currentGeneration = currentGeneration.next
        let generation = currentGeneration
        eventQueue.async { onExternalChange(document, generation) }
    }

    /// The content a suspension was protecting is readable again, or gone.
    /// Either way it is no longer at risk, so saves resume. Only
    /// `.unreadable` clears — a save failure stays until a save succeeds.
    private func resumeSavesIfSuspended() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard currentHealth == .unreadable else { return }
        logger.notice("notes file no longer unreadable; saves resumed")
        setHealth(.ok)
    }

    // MARK: - External-change watching

    /// Watches the notes file, falling back to its parent directory when the
    /// file is missing (an external editor may delete-then-recreate); the
    /// next directory event re-arms the file watch.
    private func rewatch() {
        watcher?.cancel()
        watcher = nil
        guard watchesExternalChanges else { return }

        if armWatch(path: fileURL.path) {
            return
        }

        // Snapshot before createDirectory's own syscalls overwrite errno.
        let openErrno = errno
        // On a fresh install the notes directory may not exist yet either;
        // create it so the fallback watch has something to arm on.
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logger.warning("cannot watch notes file (errno \(openErrno)); watching parent directory")
        if !armWatch(path: directory.path) {
            // Deliberately log-only rather than a `Health` case: a successful
            // save or any load re-arms the watch, so this rarely outlives its
            // cause, and a banner would name something the user can't act on.
            // Copy Diagnostics carries the trail.
            logger.error("cannot watch notes directory either (errno \(errno)); external edits will not be detected")
        }
    }

    private func armWatch(path: String) -> Bool {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        watcher = source
        source.resume()
        return true
    }

    private func handleFileEvent() {
        // Re-arm first: rename/delete (including our own atomic saves)
        // invalidate the current descriptor.
        rewatch()
        checkForExternalContent(retriesLeft: 1)
    }

    private func checkForExternalContent(retriesLeft: Int) {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            // An external editor's own atomic save can leave the file briefly
            // absent; retry once before giving up.
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.rewatch()
                    self?.checkForExternalContent(retriesLeft: retriesLeft - 1)
                }
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                // Present but unreadable: same protection as at load — never
                // overwrite content the app hasn't seen.
                logger.error("notes file changed externally but is unreadable; suspending saves to protect it")
                pendingSave?.cancel()
                pendingSave = nil
                setHealth(.unreadable)
            } else {
                // Deleted externally and confirmed absent after the retry.
                // The store must not keep serving — and later re-saving —
                // content the user deliberately deleted, so the deletion
                // propagates as an empty document. Deletion also ends a
                // suspension: the unreadable content being protected is gone.
                logger.warning("notes file removed externally; clearing store")
                resumeSavesIfSuspended()
                // Routed through the same adoption path as an edit so the two
                // can't drift: both carry the handoff hazard where a save
                // before the store catches up would undo the change — here by
                // recreating the file the user deleted.
                adoptExternalContent(MarkdownDocument(), hash: nil)
            }
            return
        }

        resumeSavesIfSuspended()

        let hash = SHA256.hash(data: data)
        guard hash != lastKnownDiskHash else { return }
        adoptExternalContent(MarkdownDocument.parse(text), hash: hash)
    }

    /// Notifies only on an actual change, so routine successful saves
    /// produce no callback traffic.
    private func setHealth(_ newValue: Health) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard newValue != currentHealth else { return }
        currentHealth = newValue
        guard let onHealthChange else { return }
        eventQueue.async { onHealthChange(newValue) }
    }
}
