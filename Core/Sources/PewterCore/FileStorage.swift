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

    private let logger = Logger.storage
    private let queue = DispatchQueue(label: "com.oakoss.Pewter.storage")
    // Callbacks are delivered on this separate serial queue so they never run
    // while `queue` is held — a handler that synchronously calls back into
    // this class (e.g. health) would otherwise deadlock. Serial, so
    // FIFO ordering across all events is preserved.
    private let eventQueue = DispatchQueue(label: "com.oakoss.Pewter.storage-events")
    private let debounceInterval: TimeInterval
    private var onExternalChange: (@Sendable (MarkdownDocument) -> Void)?
    private var onHealthChange: (@Sendable (Health) -> Void)?
    private var pendingSave: DispatchWorkItem?
    private var lastWrittenHash: SHA256Digest?
    private var watcher: DispatchSourceFileSystemObject?
    private var currentHealth: Health = .ok

    public init(fileURL: URL, debounceInterval: TimeInterval = 0.5) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
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
                queue.sync { lastWrittenHash = SHA256.hash(data: data) }
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

    public func scheduleSave(_ document: MarkdownDocument) {
        queue.sync {
            guard currentHealth != .unreadable else { return }
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.write(document)
            }
            pendingSave = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    /// Discards any scheduled-but-unfired save. Called when an external
    /// change is applied to the store: a local edit racing the application
    /// may have scheduled a save of the pre-external document, whose write
    /// would then be hash-ignored as a self-write and leave the UI and disk
    /// permanently diverged.
    public func cancelPendingSave() {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
        }
    }

    public func saveNow(_ document: MarkdownDocument) {
        queue.sync {
            guard currentHealth != .unreadable else { return }
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
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastWrittenHash = SHA256.hash(data: data)
            // Atomic writes rename over the file, changing the inode; the
            // watcher's descriptor now points at the old file.
            rewatch()
            setHealth(.ok)
        } catch {
            logger.error("failed to save notes file: \(error.localizedDescription)")
            setHealth(.saveFailed(reason: error.localizedDescription))
        }
    }

    // MARK: - External-change watching

    /// Watches the notes file, falling back to its parent directory when the
    /// file is missing (an external editor may delete-then-recreate); the
    /// next directory event re-arms the file watch.
    private func rewatch() {
        watcher?.cancel()
        watcher = nil

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
                pendingSave?.cancel()
                pendingSave = nil
                lastWrittenHash = nil
                if currentHealth == .unreadable {
                    logger.notice("unreadable notes file removed externally; saves resumed")
                    setHealth(.ok)
                }
                if let onExternalChange {
                    eventQueue.async { onExternalChange(MarkdownDocument()) }
                }
            }
            return
        }

        // A successful read means the file is readable again; a suspension
        // left in place would silently discard every edit from here on.
        // Only `.unreadable` clears here — a save failure stays until a
        // save succeeds.
        if currentHealth == .unreadable {
            logger.notice("notes file readable again; saves resumed")
            setHealth(.ok)
        }

        let hash = SHA256.hash(data: data)
        guard hash != lastWrittenHash else { return }

        // A pending debounced save holds a pre-edit document; letting it fire
        // would silently overwrite the external change.
        pendingSave?.cancel()
        pendingSave = nil

        lastWrittenHash = hash
        if let onExternalChange {
            let document = MarkdownDocument.parse(text)
            eventQueue.async { onExternalChange(document) }
        }
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
