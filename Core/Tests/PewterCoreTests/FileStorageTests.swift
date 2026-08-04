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
        storage.saveNow(document, generation: .initial)

        let reloaded = FileStorage(fileURL: url).load().document
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].text == "persist me")
    }

    @Test func loadOfMissingFileReturnsEmptyDocument() {
        let storage = FileStorage(fileURL: temporaryFileURL())
        #expect(storage.load().document.items.isEmpty)
    }

    @Test func debounceCoalescesRapidSaves() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url, debounceInterval: 0.05)
        var document = MarkdownDocument()
        for i in 1 ... 5 {
            document.append(Item(text: "item \(i)"))
            storage.scheduleSave(document, generation: .initial)
        }

        // Before the debounce fires, nothing is on disk.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try await Task.sleep(for: .milliseconds(200))
        let reloaded = FileStorage(fileURL: url).load().document
        #expect(reloaded.items.count == 5)
    }

    @Test func externalChangeIsDetectedAndSelfWritesIgnored() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)
        _ = storage.load()

        let changes = Box()
        storage.setOnExternalChange { document, generation in
            changes.append(document, generation)
        }

        // Self-write: must NOT trigger the callback.
        document.append(Item(text: "self write"))
        storage.saveNow(document, generation: .initial)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 0)

        // External write (different content, not via storage): must trigger.
        try Data("- [ ] outside edit\n".utf8).write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.count == 1)
        #expect(changes.last?.items.first?.text == "outside edit")
    }

    /// A queued save fires long after it was built, by which time an external
    /// change may have been adopted. It carries the generation it was built
    /// on, so it is refused at the write rather than trusted for having been
    /// scheduled.
    @Test func aQueuedSaveSupersededBeforeItFiresIsRefused() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url, debounceInterval: 0.1)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)

        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)

        document.append(Item(text: "should never land"))
        storage.saveNow(document, generation: .initial)
        try await waitUntilStorage { changes.count == 1 }

        // Queued on the generation the adoption superseded.
        storage.scheduleSave(document, generation: .initial)
        try await Task.sleep(for: .milliseconds(250))
        #expect(try Data(contentsOf: url) == externalBytes)
    }

    @Test func saveNowCancelsPendingScheduledSave() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url, debounceInterval: 0.1)
        var older = MarkdownDocument()
        older.append(Item(text: "older"))
        var newer = MarkdownDocument()
        newer.append(Item(text: "newer"))

        storage.scheduleSave(older, generation: .initial)
        storage.saveNow(newer, generation: .initial)
        try await Task.sleep(for: .milliseconds(250))

        #expect(FileStorage(fileURL: url).load().document.items.map(\.text) == ["newer"])
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
        let document = storage.load().document
        #expect(document.items.isEmpty)
        #expect(storage.health == .unreadable)

        var edited = MarkdownDocument()
        edited.append(Item(text: "must not land"))
        storage.saveNow(edited, generation: .initial)

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
        storage.saveNow(document, generation: .initial)
        _ = storage.load()
        #expect(storage.health != .unreadable)

        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }

        // Schedule an in-app edit, then the file becomes unreadable before
        // the debounce fires.
        document.append(Item(text: "pending edit"))
        storage.scheduleSave(document, generation: .initial)
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
        storage.saveNow(document, generation: .initial)
        #expect(storage.health == .ok)

        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }

        // Read-only directory: the atomic write's temp file can't be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        storage.saveNow(document, generation: .initial)
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
        storage.saveNow(document, generation: .initial)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.all.count == countAfterFailure)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        storage.saveNow(document, generation: .initial)
        try await waitUntilStorage { changes.all.last == .ok }
        #expect(storage.health == .ok)

        // Values must arrive in transition order — a stale .ok delivered
        // after the failure would clear a live banner. The first .ok is the
        // registration delivery; the recovery .ok must come after the
        // failure.
        let all = changes.all
        let failIndex = try #require(all.firstIndex {
            if case .saveFailed = $0 {
                true
            } else {
                false
            }
        })
        let okIndex = try #require(all.lastIndex(of: .ok))
        #expect(failIndex < okIndex)

        // Change-only contract: a repeat healthy save produces no callback.
        let countAfterRecovery = all.count
        storage.saveNow(document, generation: .initial)
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
        storage.saveNow(document, generation: .initial)
        _ = storage.load()

        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }
        let external = Box()
        storage.setOnExternalChange { external.append($0, $1) }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        storage.saveNow(document, generation: .initial)
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
        // No .ok after the failure — the only .ok is the registration
        // delivery that preceded it.
        let all = changes.all
        let failIndex = try #require(all.firstIndex {
            if case .saveFailed = $0 {
                true
            } else {
                false
            }
        })
        #expect(!all[(failIndex + 1)...].contains(.ok))
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
        recordExternalChanges(on: storage, into: external)
        _ = storage.load()
        #expect(storage.health == .unreadable)

        // The natural remedy for a corrupt file: delete it and start over.
        try FileManager.default.removeItem(at: url)
        try await waitUntilStorage { external.count == 1 }
        #expect(external.last?.items.isEmpty == true)
        try await waitUntilStorage { changes.all == [.ok, .unreadable, .ok] }

        // Saves must resume, not stay suspended forever.
        var document = MarkdownDocument()
        document.append(Item(text: "fresh start"))
        storage.saveNow(document, generation: external.generation)
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text) == ["fresh start"])
    }

    @Test func registrationDeliversCurrentHealth() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage(fileURL: url)
        _ = storage.load()

        // Wiring after the transition still surfaces it: registration
        // delivers the current value, so no consumer-side initial read
        // exists to race the wiring.
        let changes = HealthBox()
        storage.setOnHealthChange { changes.append($0) }
        try await waitUntilStorage { changes.all == [.unreadable] }
        // Settle, then re-assert: "once" is part of the contract, and the
        // wait alone would miss a duplicate delivery arriving late.
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.all == [.unreadable])
        #expect(storage.health == .unreadable)
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
        let external = Box()
        recordExternalChanges(on: storage, into: external)
        _ = storage.load()
        #expect(storage.health == .unreadable)

        // External repair: valid content replaces the unreadable bytes.
        try Data("- [ ] repaired\n".utf8).write(to: url, options: .atomic)

        let deadline = ContinuousClock.now + .seconds(2)
        while storage.health == .unreadable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(storage.health != .unreadable)
        try await waitUntilStorage { changes.all == [.ok, .unreadable, .ok] }
        // Health resumes before the adoption is delivered, so waiting on
        // health alone would let the save race the delivery it must be
        // built on.
        try await waitUntilStorage { external.count == 1 }

        // Saves work again after recovery.
        var document = MarkdownDocument()
        document.append(Item(text: "post-recovery edit"))
        storage.saveNow(document, generation: external.generation)
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text) == ["post-recovery edit"])
    }

    @Test func confirmedExternalDeletionClearsTheStore() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "deleted outside"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }
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
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }
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
        storage.saveNow(document, generation: .initial)
        _ = storage.load()

        // Schedule a save, then simulate an external edit landing before the
        // debounce fires. The stale save must not clobber the external edit.
        document.append(Item(text: "in-memory edit"))
        storage.scheduleSave(document, generation: .initial)
        try await Task.sleep(for: .milliseconds(50))
        try Data("- [ ] external wins\n".utf8).write(to: url, options: .atomic)

        try await Task.sleep(for: .milliseconds(400))
        let final = FileStorage(fileURL: url).load().document
        #expect(final.items.map(\.text) == ["external wins"])
    }

    @Test func saveDoesNotOverwriteAnExternalEditTheWatcherMissed() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // No watcher at all: the save has to protect itself, which is the
        // whole point — a dead or late watcher must not cost the user data.
        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }

        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)

        document.append(Item(text: "must not land"))
        storage.saveNow(document, generation: .initial)

        #expect(try Data(contentsOf: url) == externalBytes)
        try await waitUntilStorage { changes.count == 1 }
        // Settle before re-asserting: a second delivery would clear the
        // store's undo history twice.
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 1)
        #expect(changes.last?.items.map(\.text) == ["outside edit"])
    }

    @Test func saveDoesNotOverwriteAFileTheAppHasNeverRead() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingBytes = Data("- [ ] written before we looked\n".utf8)
        try existingBytes.write(to: url)

        // Never loaded, so nothing of ours is on disk as far as the storage
        // knows — a file that exists anyway is content it has never seen.
        let storage = FileStorage.unwatched(fileURL: url)
        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }

        var document = MarkdownDocument()
        document.append(Item(text: "must not land"))
        storage.saveNow(document, generation: .initial)

        #expect(try Data(contentsOf: url) == existingBytes)
        try await waitUntilStorage { changes.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 1)
        #expect(changes.last?.items.map(\.text) == ["written before we looked"])
    }

    @Test func saveOfOurOwnContentProceedsWithoutAnExternalCallback() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }

        // The pre-write check must not mistake the app's own last write for
        // an external edit, or every second save would be refused.
        document.append(Item(text: "second save"))
        storage.saveNow(document, generation: .initial)

        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 0)
        #expect(storage.health == .ok)
        let reloaded = FileStorage(fileURL: url).load().document
        #expect(reloaded.items.map(\.text) == ["original", "second save"])
    }

    /// The refusal is only half the protection: adoption reaches the store
    /// asynchronously, so until the store catches up every document a caller
    /// holds is on the generation before it. The quit flush is exactly such a
    /// caller.
    @Test func repeatedSavesOnAStaleGenerationKeepProtectingTheExternalEdit() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        // Registered, but standing in for a store whose main-queue hop has
        // not run yet, so it is still on the earlier generation.
        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }

        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)

        document.append(Item(text: "must not land"))
        storage.saveNow(document, generation: .initial)
        storage.saveNow(document, generation: .initial)
        storage.saveNow(document, generation: .initial)

        #expect(try Data(contentsOf: url) == externalBytes)
    }

    @Test func savesResumeOnceTheStoreIsOnTheAdoptedGeneration() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)

        try Data("- [ ] outside edit\n".utf8).write(to: url, options: .atomic)
        storage.saveNow(document, generation: .initial)
        try await waitUntilStorage { changes.count == 1 }

        // The store has caught up, so a save built on the adopted document
        // must land — a refusal that never lifts is its own data loss.
        var adopted = try #require(changes.last)
        adopted.append(Item(text: "typed after adopting"))
        storage.saveNow(adopted, generation: changes.generation)

        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["outside edit", "typed after adopting"])
    }

    /// Two external edits can be adopted before the store applies the first.
    /// A save built on the first delivery is still stale, so it must be
    /// refused rather than trusted for carrying a generation the storage did
    /// once hand out. Runs with a live watcher — the write path can't adopt
    /// twice, since its own refusal stops the second save before it inspects
    /// the file.
    @Test func aSaveOnAnEarlierDeliverysGenerationIsStillRefused() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)
        _ = storage.load()

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)

        try Data("- [ ] first outside edit\n".utf8).write(to: url, options: .atomic)
        try await waitUntilStorage { changes.count == 1 }
        let firstGeneration = try #require(changes.generations.first)

        let secondBytes = Data("- [ ] second outside edit\n".utf8)
        try secondBytes.write(to: url, options: .atomic)
        try await waitUntilStorage { changes.count == 2 }

        storage.saveNow(document, generation: firstGeneration)

        #expect(try Data(contentsOf: url) == secondBytes)
    }

    /// Relaunch ordering: notes already on disk, loaded, then edited. Loading
    /// has to record what it read, or the first save sees the app's own
    /// content as foreign, adopts it back as an external change, and takes the
    /// edit and the undo history with it.
    @Test func theFirstSaveAfterLoadingExistingNotesLands() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("- [ ] from a previous launch\n".utf8).write(to: url, options: .atomic)

        let storage = FileStorage.unwatched(fileURL: url)
        let changes = Box()
        recordExternalChanges(on: storage, into: changes)
        let loaded = storage.load()

        var document = loaded.document
        document.append(Item(text: "typed after relaunch"))
        storage.saveNow(document, generation: loaded.generation)

        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["from a previous launch", "typed after relaunch"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 0)
    }

    /// A store rebuilt against a storage that has already adopted an external
    /// change must not start behind it: nothing would move it forward, since
    /// the known hash suppresses further deliveries and a refused save returns
    /// before it would adopt, so every save would be refused for the life of
    /// the process. `load()` hands back the generation that prevents it, and
    /// the baseline stays a value the storage no longer accepts.
    @Test func loadHandsBackTheGenerationARebuiltStoreMustSaveOn() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)
        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)
        storage.saveNow(document, generation: .initial)
        try await waitUntilStorage { changes.count == 1 }
        #expect(changes.generation != .initial)

        let loaded = storage.load()
        #expect(loaded.generation != .initial)

        var stale = loaded.document
        stale.append(Item(text: "must not land"))
        storage.saveNow(stale, generation: .initial)
        #expect(try Data(contentsOf: url) == externalBytes)

        var rebuilt = loaded.document
        rebuilt.append(Item(text: "typed after reload"))
        storage.saveNow(rebuilt, generation: loaded.generation)
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["outside edit", "typed after reload"])
    }

    /// `scheduleSave` is how every user edit reaches disk — `saveNow` is only
    /// the quit flush — so the check has to hold on the debounced path, not
    /// just the immediate one.
    @Test func aDebouncedSaveIsCheckedBeforeItWrites() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url, debounceInterval: 0.05)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        storage.setOnExternalChange { changes.append($0, $1) }

        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)

        document.append(Item(text: "must not land"))
        storage.scheduleSave(document, generation: .initial)
        try await Task.sleep(for: .milliseconds(250))

        #expect(try Data(contentsOf: url) == externalBytes)
        try await waitUntilStorage { changes.count == 1 }
    }

    /// An external deletion carries the same handoff hazard as an edit: until
    /// the store stops serving the deleted notes, a save puts them back.
    @Test func aSaveDoesNotResurrectADeletionTheStoreHasNotAppliedYet() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "deleted outside"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)
        _ = storage.load()

        try FileManager.default.removeItem(at: url)
        try await waitUntilStorage { changes.count == 1 }

        storage.saveNow(document, generation: .initial)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // On the generation the deletion arrived on, the same document is the
        // user's next set of notes rather than a resurrection of the old.
        storage.saveNow(document, generation: changes.generation)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func adoptionWithNoStoreAttachedRefusesEverySubsequentSave() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // No handler: nothing will ever apply the external content, so the
        // divergence is permanent and every later save must keep refusing.
        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)

        document.append(Item(text: "must not land"))
        storage.saveNow(document, generation: .initial)
        storage.saveNow(document, generation: .initial)

        #expect(try Data(contentsOf: url) == externalBytes)
    }

    /// Refusing without a store must not latch: nothing is recorded as seen,
    /// so the next save re-inspects the file and a store wired up in the
    /// meantime is handed the content instead of being stuck refusing.
    @Test func aStoreWiredUpAfterADetachedChangeStillReceivesIt() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let externalBytes = Data("- [ ] outside edit\n".utf8)
        try externalBytes.write(to: url, options: .atomic)

        document.append(Item(text: "must not land"))
        storage.saveNow(document, generation: .initial)
        #expect(try Data(contentsOf: url) == externalBytes)

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)
        storage.saveNow(document, generation: .initial)
        try await waitUntilStorage { changes.count == 1 }
        #expect(changes.last?.items.map(\.text) == ["outside edit"])

        var adopted = try #require(changes.last)
        adopted.append(Item(text: "typed after adopting"))
        storage.saveNow(adopted, generation: changes.generation)
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["outside edit", "typed after adopting"])
    }

    @Test func fileTurningUnreadableBeforeASaveSuspendsInsteadOfOverwriting() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let health = HealthBox()
        storage.setOnHealthChange { health.append($0) }

        let invalidBytes = Data([0xFF, 0xFE, 0x00])
        try invalidBytes.write(to: url, options: .atomic)

        document.append(Item(text: "must not land"))
        storage.saveNow(document, generation: .initial)

        #expect(try Data(contentsOf: url) == invalidBytes)
        #expect(storage.health == .unreadable)
        // The banner depends on the callback, not the readable property.
        try await waitUntilStorage { health.all.last == .unreadable }
    }

    /// The suspension this entry point sets must not need the watcher to
    /// lift, since a dead watcher is the premise of the whole pre-write
    /// check — otherwise saving stays off until the app relaunches.
    @Test func repairingAnUnreadableFileResumesSavesWithoutARelaunch() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        let changes = Box()
        recordExternalChanges(on: storage, into: changes)

        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        storage.saveNow(document, generation: .initial)
        #expect(storage.health == .unreadable)

        try Data("- [ ] repaired by hand\n".utf8).write(to: url, options: .atomic)
        storage.saveNow(document, generation: .initial)
        #expect(storage.health == .ok)

        try await waitUntilStorage { changes.count == 1 }
        var adopted = try #require(changes.last)
        adopted.append(Item(text: "saved after repair"))
        storage.saveNow(adopted, generation: changes.generation)

        #expect(FileStorage(fileURL: url).load().document.items.map(\.text)
            == ["repaired by hand", "saved after repair"])
    }

    /// Accepted limitation, pinned so it can't drift silently: a deletion the
    /// watcher missed is indistinguishable from a fresh install at the write,
    /// so the save recreates the file. Tracked as pw-px7.
    @Test func saveRecreatesAFileDeletedWithoutAWatcherEvent() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let storage = FileStorage.unwatched(fileURL: url)
        var document = MarkdownDocument()
        document.append(Item(text: "original"))
        storage.saveNow(document, generation: .initial)

        try FileManager.default.removeItem(at: url)
        storage.saveNow(document, generation: .initial)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileStorage(fileURL: url).load().document.items.map(\.text) == ["original"])
    }
}

private func recordExternalChanges(on storage: FileStorage, into box: Box) {
    storage.setOnExternalChange { box.append($0, $1) }
}

/// Thread-safe accumulator for watcher callbacks. Stands in for `ListStore`:
/// it keeps the generation each delivery arrived on, which is what a later
/// save has to be built on to be accepted.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [MarkdownDocument] = []
    private var latest = FileStorage.DocumentGeneration.initial
    private var delivered: [FileStorage.DocumentGeneration] = []

    func append(_ document: MarkdownDocument, _ generation: FileStorage.DocumentGeneration) {
        lock.withLock {
            documents.append(document)
            delivered.append(generation)
            latest = generation
        }
    }

    var count: Int {
        lock.withLock { documents.count }
    }

    var last: MarkdownDocument? {
        lock.withLock { documents.last }
    }

    /// The generation of the most recent delivery, or `.initial` before any.
    var generation: FileStorage.DocumentGeneration {
        lock.withLock { latest }
    }

    var generations: [FileStorage.DocumentGeneration] {
        lock.withLock { delivered }
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
