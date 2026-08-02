import CryptoKit
import Foundation
import os

/// Owns the notes file: debounced atomic writes, and a file watcher that
/// reloads on external edits while ignoring our own saves.
public final class FileStorage: @unchecked Sendable {
    public let fileURL: URL

    public enum StorageEvent: Sendable {
        case saveFailed(String)
        case saveSucceeded
        /// The notes file exists but can't be read; saves are suspended so
        /// the app can never overwrite content it hasn't seen.
        case protectedUnreadable
        /// A previously unreadable file became readable again; saves resumed.
        case recovered
    }

    private let logger = Logger.storage
    private let queue = DispatchQueue(label: "com.oakoss.Pewter.storage")
    // Callbacks are delivered on this separate serial queue so they never run
    // while `queue` is held — a handler that synchronously calls back into
    // this class (e.g. savesSuspended) would otherwise deadlock. Serial, so
    // FIFO ordering across all events is preserved.
    private let eventQueue = DispatchQueue(label: "com.oakoss.Pewter.storage-events")
    private let debounceInterval: TimeInterval
    private var onExternalChange: (@Sendable (MarkdownDocument) -> Void)?
    private var onStorageEvent: (@Sendable (StorageEvent) -> Void)?
    private var pendingSave: DispatchWorkItem?
    private var lastWrittenHash: SHA256Digest?
    private var watcher: DispatchSourceFileSystemObject?
    private var suspended = false

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

    /// True when the notes file exists but can't be read (detected at load
    /// or after an external change); writes are disabled so the app can
    /// never overwrite content it hasn't seen.
    public var savesSuspended: Bool {
        queue.sync { suspended }
    }

    /// Sets the handler called with the freshly parsed document when the file
    /// changes on disk from outside the app. Invoked on an arbitrary queue.
    public func setOnExternalChange(_ handler: @escaping @Sendable (MarkdownDocument) -> Void) {
        queue.sync { onExternalChange = handler }
    }

    /// Sets the handler for save results and protection events. Invoked on
    /// an arbitrary queue. Failures usually repeat (disk full, permissions),
    /// so surface them persistently; `saveSucceeded` signals recovery so a
    /// stale failure banner can clear.
    public func setOnStorageEvent(_ handler: @escaping @Sendable (StorageEvent) -> Void) {
        queue.sync { onStorageEvent = handler }
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
                queue.sync { suspended = true }
            }
        }
        queue.sync { rewatch() }
        return document
    }

    public func scheduleSave(_ document: MarkdownDocument) {
        queue.sync {
            guard !suspended else { return }
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
            guard !suspended else { return }
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
            emit(.saveSucceeded)
        } catch {
            logger.error("failed to save notes file: \(error.localizedDescription)")
            emit(.saveFailed(error.localizedDescription))
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
                suspended = true
                pendingSave?.cancel()
                pendingSave = nil
                emit(.protectedUnreadable)
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
                if suspended {
                    suspended = false
                    emit(.recovered)
                }
                if let onExternalChange {
                    eventQueue.async { onExternalChange(MarkdownDocument()) }
                }
            }
            return
        }

        // A successful read means the file is healthy again; a suspension
        // left in place would silently discard every edit from here on.
        if suspended {
            suspended = false
            emit(.recovered)
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

    private func emit(_ event: StorageEvent) {
        guard let onStorageEvent else { return }
        eventQueue.async { onStorageEvent(event) }
    }
}
