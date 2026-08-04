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
    private var onExternalChange: (@Sendable (MarkdownDocument) -> Void)?
    private var onHealthChange: (@Sendable (Health) -> Void)?
    private var pendingSave: DispatchWorkItem?
    /// Digest of the bytes the storage believes are on disk — its own last
    /// write, or content it adopted from an external edit. `nil` means it
    /// holds no belief, so anything on disk is content it has never seen.
    private var lastKnownDiskHash: SHA256Digest?
    /// Adoptions handed to the store but not yet applied. The handoff is
    /// asynchronous, so until it lands every document a caller could save
    /// still predates the adopted content — writing one would destroy the
    /// edit that was just protected. A count rather than a flag because
    /// rapid external edits adopt more than once before the first is
    /// applied, and the earlier acknowledgement must not clear the gate the
    /// later one is holding.
    private var unacknowledgedAdoptions = 0
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

    /// Sets the handler called with the freshly parsed document when the file
    /// changes on disk from outside the app. Invoked on an arbitrary queue.
    public func setOnExternalChange(_ handler: @escaping @Sendable (MarkdownDocument) -> Void) {
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

    public func load() -> MarkdownDocument {
        var document = MarkdownDocument()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) {
                queue.sync { lastKnownDiskHash = SHA256.hash(data: data) }
                document = MarkdownDocument.parse(text)
            } else {
                // The file exists but can't be read (permissions, non-UTF8).
                // Proceeding with an empty document and live saves would
                // overwrite the user's data — refuse to write instead.
                logger.error("notes file exists but is unreadable; suspending saves to protect it")
                queue.sync { setHealth(.unreadable) }
            }
        }
        queue.sync { rewatch() }
        return document
    }

    /// Neither entry point gates on `health`: the write consults the file
    /// itself, which is a stricter test and — unlike a cached health value —
    /// re-evaluates every time, so a repaired file resumes saving on its own.
    public func scheduleSave(_ document: MarkdownDocument) {
        queue.sync {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.write(document)
            }
            pendingSave = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    /// Called by the store once it has applied an external change — exactly
    /// once per delivery, since each call clears only its own adoption.
    /// Until every delivery is acknowledged saves are refused outright: the
    /// handoff is asynchronous, so any document a caller holds still
    /// predates the adopted content and saving it would overwrite the edit.
    public func acknowledgeExternalChange() {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            guard unacknowledgedAdoptions > 0 else {
                // Counting calls only holds while they pair 1:1 with
                // deliveries. An unmatched one would bank credit against a
                // real adoption still in flight and open the gate on it, so
                // it is a caller bug, not something to absorb quietly.
                assertionFailure("acknowledged an external change that was never delivered")
                logger.error("acknowledged an external change that was never delivered; ignoring")
                return
            }
            unacknowledgedAdoptions -= 1
        }
    }

    public func saveNow(_ document: MarkdownDocument) {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            write(document)
        }
    }

    private func write(_ document: MarkdownDocument) {
        guard let data = document.serialized().data(using: .utf8) else {
            assertionFailure("notes document not encodable as UTF-8")
            logger.error("notes document not encodable as UTF-8; save skipped")
            return
        }
        guard unacknowledgedAdoptions == 0 else {
            if !loggedRefusedSave {
                loggedRefusedSave = true
                logger.warning("save refused: an adopted external change has not reached the store yet")
            }
            return
        }
        loggedRefusedSave = false
        switch inspectOnDisk() {
        case .absent, .ours:
            resumeSavesIfSuspended()
        case .unreadable:
            // Same protection as at load: never overwrite content the app
            // can't read, so can't have seen. Re-arm on the way out — landing
            // here at all is evidence the watcher missed the change that
            // broke the file, and without a watcher nothing else re-reads it.
            logger.error("notes file is unreadable at save time; suspending saves to protect it")
            rewatch()
            setHealth(.unreadable)
            return
        case let .foreign(text, hash):
            resumeSavesIfSuspended()
            logger.warning("notes file changed on disk with no watcher event; adopting it rather than overwriting")
            rewatch()
            adoptExternalContent(MarkdownDocument.parse(text), hash: hash)
            return
        }
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
        case unreadable
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
            logger.error("cannot read notes file at save time: \(error.localizedDescription)")
            return .unreadable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            // Distinct from the throw above: the remedy is re-saving the file
            // as UTF-8, not fixing permissions, and the caller's message
            // can't tell them apart.
            logger.error("notes file is not valid UTF-8 at save time")
            return .unreadable
        }
        let hash = SHA256.hash(data: data)
        return hash == lastKnownDiskHash ? .ours : .foreign(text: text, hash: hash)
    }

    /// Takes what is on disk as the truth and hands it to the store — an
    /// edit, or an empty document for a deletion. External changes win: the
    /// app's copy is always re-derivable from the file, and the reverse
    /// isn't. Any queued save is dropped with it, since it holds a document
    /// whose write would undo the change just adopted.
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
        unacknowledgedAdoptions += 1
        eventQueue.async { onExternalChange(document) }
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
