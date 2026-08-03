import Foundation
@testable import PewterCore
import Testing

struct FileStorageTests {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "pewter-tests-\(UUID().uuidString)/notes.md")
    }

    @Test func savesAndLoadsRoundTrip() {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "persist me"))
        storage.saveNow(document)

        let reloaded = FileStorage(fileURL: url).load()
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].text == "persist me")
    }

    @Test func loadOfMissingFileReturnsEmptyDocument() {
        let storage = FileStorage(fileURL: temporaryFileURL())
        #expect(storage.load().items.isEmpty)
    }

    @Test func debounceCoalescesRapidSaves() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url, debounceInterval: 0.05)
        var document = MarkdownDocument()
        for i in 1 ... 5 {
            document.append(Item(text: "item \(i)"))
            storage.scheduleSave(document)
        }

        // Before the debounce fires, nothing is on disk.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try await Task.sleep(for: .milliseconds(200))
        let reloaded = FileStorage(fileURL: url).load()
        #expect(reloaded.items.count == 5)
    }

    @Test func externalChangeIsDetectedAndSelfWritesIgnored() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document)
        _ = storage.load()

        let changes = Box()
        storage.setOnExternalChange { document in
            changes.append(document)
        }

        // Self-write: must NOT trigger the callback.
        document.append(Item(text: "self write"))
        storage.saveNow(document)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 0)

        // External write (different content, not via storage): must trigger.
        try Data("- [ ] outside edit\n".utf8).write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.count == 1)
        #expect(changes.last?.items.first?.text == "outside edit")
    }

    @Test func cancelPendingSaveDiscardsScheduledWrite() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url, debounceInterval: 0.1)
        var document = MarkdownDocument()
        document.append(Item(text: "should never land"))
        storage.scheduleSave(document)
        storage.cancelPendingSave()

        try await Task.sleep(for: .milliseconds(250))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func saveNowCancelsPendingScheduledSave() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url, debounceInterval: 0.1)
        var older = MarkdownDocument()
        older.append(Item(text: "older"))
        var newer = MarkdownDocument()
        newer.append(Item(text: "newer"))

        storage.scheduleSave(older)
        storage.saveNow(newer)
        try await Task.sleep(for: .milliseconds(250))

        #expect(FileStorage(fileURL: url).load().items.map(\.text) == ["newer"])
    }

    @Test func unreadableExistingFileSuspendsSaves() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Invalid UTF-8 makes the decode fail while the file exists.
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage(fileURL: url)
        let document = storage.load()
        #expect(document.items.isEmpty)
        #expect(storage.health == .unreadable)

        var edited = MarkdownDocument()
        edited.append(Item(text: "must not land"))
        storage.saveNow(edited)

        // The original bytes survive: a broken load can't overwrite the file.
        #expect(try Data(contentsOf: url) == Data([0xFF, 0xFE, 0x00]))
    }

    @Test func runtimeUnreadableFileSuspendsAndProtects() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Generous debounce: the protection path costs a fixed ~100 ms
        // (watcher read retry) before suspension lands, and it must win the
        // race against this scheduled save even on a loaded CI machine.
        let storage = FileStorage(fileURL: url, debounceInterval: 1.0)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document)
        _ = storage.load()
        #expect(storage.health != .unreadable)

        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }

        // Schedule an in-app edit, then the file becomes unreadable before
        // the debounce fires.
        document.append(Item(text: "pending edit"))
        storage.scheduleSave(document)
        let invalidBytes = Data([0xFF, 0xFE, 0x00])
        try invalidBytes.write(to: url, options: .atomic)

        let deadline = ContinuousClock.now + .seconds(2)
        while storage.health != .unreadable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(storage.health == .unreadable)
        // The banner depends on the callback, not the readable property.
        try await waitUntilStorage { changes.all.last == .unreadable }

        // Past the debounce window: the pending save must not have landed —
        // the unreadable content the app never saw stays intact.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try Data(contentsOf: url) == invalidBytes)
    }

    @Test func healthReportsSaveFailureAndRecovery() async throws {
        // chmod 0o555 does not block root; as root the save would succeed
        // and this test would time out with a misleading message.
        try #require(getuid() != 0, "cannot exercise permission failures as root")

        let url = temporaryFileURL()
        let directory = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "first"))
        storage.saveNow(document)
        #expect(storage.health == .ok)

        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }

        // Read-only directory: the atomic write's temp file can't be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        storage.saveNow(document)
        try await waitUntilStorage { changes.all.contains {
            if case .saveFailed = $0 {
                true
            } else {
                false
            }
        } }
        if case .saveFailed = storage.health {} else {
            Issue.record("expected .saveFailed, got \(storage.health)")
        }

        // A repeat failure with the same reason coalesces — the identical
        // banner is already showing.
        let countAfterFailure = changes.all.count
        storage.saveNow(document)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.all.count == countAfterFailure)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        storage.saveNow(document)
        try await waitUntilStorage { changes.all.last == .ok }
        #expect(storage.health == .ok)

        // Values must arrive in transition order — a stale .ok delivered
        // after the failure would clear a live banner.
        let all = changes.all
        let failIndex = all.firstIndex {
            if case .saveFailed = $0 {
                true
            } else {
                false
            }
        }
        let okIndex = all.firstIndex(of: .ok)
        #expect(failIndex != nil && okIndex != nil && failIndex! < okIndex!)

        // Change-only contract: a repeat healthy save produces no callback.
        let countAfterRecovery = all.count
        storage.saveNow(document)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.all.count == countAfterRecovery)
    }

    @Test func saveFailurePersistsAcrossExternalReads() async throws {
        try #require(getuid() != 0, "cannot exercise permission failures as root")

        let url = temporaryFileURL()
        let directory = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "first"))
        storage.saveNow(document)
        _ = storage.load()

        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }
        let external = Box()
        storage.setOnExternalChange { external.append($0) }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        storage.saveNow(document)
        try await waitUntilStorage { changes.all.contains {
            if case .saveFailed = $0 {
                true
            } else {
                false
            }
        } }

        // A non-atomic write modifies the existing file in place (needs file
        // permission only, so it succeeds despite the read-only directory)
        // and triggers the watcher.
        try Data("- [ ] outside edit\n".utf8).write(to: url)
        try await waitUntilStorage { external.count == 1 }

        // The read working again says nothing about writes working again.
        if case .saveFailed = storage.health {} else {
            Issue.record("expected .saveFailed to persist, got \(storage.health)")
        }
        #expect(!changes.all.contains(.ok))
    }

    @Test func deletingUnreadableFileRestoresHealthAndSaves() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage(fileURL: url)
        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }
        let external = Box()
        storage.setOnExternalChange { external.append($0) }
        _ = storage.load()
        #expect(storage.health == .unreadable)

        // The natural remedy for a corrupt file: delete it and start over.
        try FileManager.default.removeItem(at: url)
        try await waitUntilStorage { external.count == 1 }
        #expect(external.last?.items.isEmpty == true)
        try await waitUntilStorage { changes.all.last == .ok }

        // Saves must resume, not stay suspended forever.
        var document = MarkdownDocument()
        document.append(Item(text: "fresh start"))
        storage.saveNow(document)
        #expect(FileStorage(fileURL: url).load().items.map(\.text) == ["fresh start"])
    }

    @Test func healthDetectedBeforeWiringIsReadNotReplayed() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage(fileURL: url)
        _ = storage.load()

        // Wiring after the transition: the callback stays silent — the
        // consumer must read `health` after wiring, and that read sees the
        // problem detected at load.
        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }
        #expect(storage.health == .unreadable)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.all.isEmpty)
    }

    @Test func suspensionClearsWhenFileBecomesReadable() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage(fileURL: url)
        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }
        _ = storage.load()
        #expect(storage.health == .unreadable)

        // External repair: valid content replaces the unreadable bytes.
        try Data("- [ ] repaired\n".utf8).write(to: url, options: .atomic)

        let deadline = ContinuousClock.now + .seconds(2)
        while storage.health == .unreadable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(storage.health != .unreadable)
        try await waitUntilStorage { changes.all.last == .ok }
        #expect(changes.all == [.unreadable, .ok])

        // Saves work again after recovery.
        var document = MarkdownDocument()
        document.append(Item(text: "post-recovery edit"))
        storage.saveNow(document)
        #expect(FileStorage(fileURL: url).load().items.map(\.text) == ["post-recovery edit"])
    }

    @Test func confirmedExternalDeletionClearsTheStore() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "deleted outside"))
        storage.saveNow(document)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0) }
        _ = storage.load()

        try FileManager.default.removeItem(at: url)

        // After the retry confirms absence, the deletion must propagate as
        // an empty document — otherwise a later save resurrects it.
        try await waitUntilStorage { changes.count == 1 }
        #expect(changes.last?.items.isEmpty == true)
    }

    @Test func watcherSurvivesDeleteAndRecreate() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0) }
        _ = storage.load()

        // vim-style: delete, then write a new file at the same path.
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(200))
        try Data("- [ ] recreated\n".utf8).write(to: url)

        try await Task.sleep(for: .milliseconds(400))
        #expect(changes.last?.items.first?.text == "recreated")
    }

    @Test func externalEditCancelsPendingDebouncedSave() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url, debounceInterval: 0.2)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document)
        _ = storage.load()

        // Schedule a save, then simulate an external edit landing before the
        // debounce fires. The stale save must not clobber the external edit.
        document.append(Item(text: "in-memory edit"))
        storage.scheduleSave(document)
        try await Task.sleep(for: .milliseconds(50))
        try Data("- [ ] external wins\n".utf8).write(to: url, options: .atomic)

        try await Task.sleep(for: .milliseconds(400))
        let final = FileStorage(fileURL: url).load()
        #expect(final.items.map(\.text) == ["external wins"])
    }
}

/// Thread-safe accumulator for watcher callbacks.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [MarkdownDocument] = []

    func append(_ document: MarkdownDocument) {
        lock.withLock { documents.append(document) }
    }

    var count: Int {
        lock.withLock { documents.count }
    }

    var last: MarkdownDocument? {
        lock.withLock { documents.last }
    }
}

/// Thread-safe accumulator for health changes.
private final class HealthBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileStorage.Health] = []

    func append(_ value: FileStorage.Health) {
        lock.withLock { values.append(value) }
    }

    var all: [FileStorage.Health] {
        lock.withLock { values }
    }
}

private struct WaitTimeout: Error {}

/// Throws on timeout so follow-up expectations don't fail for cascading
/// reasons — the root cause stays the only failure in the output.
private func waitUntilStorage(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for storage condition")
            throw WaitTimeout()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
