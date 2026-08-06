import Foundation
@testable import PewterCore
import Testing

struct UnreadableCauseTests {
    /// The permission arm is the one that earns a distinct remedy, so it is
    /// the one classification that has to be right. Every other errno maps to
    /// generic advice on purpose — inventing a repair is worse than admitting
    /// there isn't a specific one.
    @Test func aPermissionDenialIsClassifiedApartFromOtherReadFailures() throws {
        // chmod does not constrain root, so the read would succeed and the
        // classification under test would never happen.
        try #require(getuid() != 0, "cannot exercise permission failures as root")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pewter-cause-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: directory.appending(path: "notes.md").path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "notes.md")
        try Data("- [ ] secret\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        do {
            _ = try Data(contentsOf: url)
            Issue.record("expected the read to fail")
        } catch {
            #expect(UnreadableCause(readError: error) == .notPermitted)
        }
    }

    /// End to end, because the cause was dropped at the `Health` boundary
    /// rather than at the read: a permission problem and a mis-encoded file
    /// travelled fine until they became one undifferentiated banner. Every
    /// other test here breaks the file with invalid UTF-8, so this is the only
    /// one that would notice the permission arm being wired to the wrong copy.
    @MainActor
    @Test func aPermissionProblemReachesEverySurfaceAsAPermissionProblem() throws {
        try #require(getuid() != 0, "cannot exercise permission failures as root")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pewter-cause-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "notes.md")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("- [ ] unreachable\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))

        #expect(store.placeholderCause == .notPermitted)
        #expect(store.unavailability == .unreadable(cause: .notPermitted))
        #expect(store.health.bannerMessage?.contains("permissions") == true)
        #expect(store.add(text: "typed over a locked file")
            == .refused(.unreadable(cause: .notPermitted)))
        #expect(CaptureFeedback.notesUnavailable(.unreadable(cause: .notPermitted)).message
            == "Can't read your notes file — check its permissions")
    }

    /// A repair that changes the failure mode instead of fixing it. The new
    /// cause has to be taken up, or every surface keeps naming the repair the
    /// user has already made and they are sent to redo it.
    @MainActor
    @Test func aRepairThatChangesTheFailureModeIsTakenUp() throws {
        try #require(getuid() != 0, "cannot exercise permission failures as root")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pewter-cause-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "notes.md")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("- [ ] unreachable\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = ListStore.loadFrom(storage: FileStorage.unwatched(fileURL: url))
        #expect(store.placeholderCause == .notPermitted)

        // Permissions fixed, but re-saved in an encoding the app can't read:
        // still a placeholder, different repair.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Data([0xFF, 0xFE, 0x00]).write(to: url, options: .atomic)
        store.reloadIfPlaceholder()

        #expect(store.documentIsPlaceholder, "still unreadable, so still a placeholder")
        #expect(store.placeholderCause == .notUTF8)
        #expect(store.unavailability == .unreadable(cause: .notUTF8))
        #expect(store.health.bannerMessage?.contains("UTF-8") == true)
    }

    /// A recovering placeholder passes through a state where health has
    /// already cleared but the adoption carrying the real notes has not landed
    /// yet — the two arrive on separate main-queue turns. Input is still
    /// refused there, correctly, but naming the old cause tells a user who has
    /// this second finished repairing their file to go and repair it again.
    /// The remedy is "try again", and the only thing that knows so is the
    /// generation.
    @MainActor
    @Test func aRecoveringPlaceholderStopsNamingTheRepairAlreadyMade() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pewter-cause-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        #expect(store.unavailability == .unreadable(cause: .notUTF8))

        // Repaired, and noticed by the storage rather than by the store: the
        // adoption is queued to main, which this test never yields to, so the
        // store is left holding the placeholder exactly as it would be for the
        // turn between the two deliveries.
        try Data("- [ ] repaired by hand\n".utf8).write(to: url, options: .atomic)
        storage.reactToFileEvent()

        #expect(store.documentIsPlaceholder, "the real notes have not been applied yet")
        #expect(storage.health == .ok, "and the file reads perfectly")
        #expect(store.unavailability == .adoptionInFlight)
        #expect(CaptureFeedback.notesUnavailable(.adoptionInFlight).message
            == "Your notes just changed on disk — capture again")
    }

    /// A save failure outlives a retry that finds the file readable: reading
    /// working says nothing about whether writing does. The mirror therefore
    /// has to be *handed* the health the storage reconciled to — deriving it
    /// from the read ("unreadable? no → `.ok`") downgrades a live save-failure
    /// banner to no banner at all, with every test still green.
    ///
    /// Covers the `refreshFromDisk` path, the reachable one. `load()`'s twin
    /// is correct by construction for the same reason: it hands back
    /// `currentHealth` rather than a verdict derived from the read.
    @MainActor
    @Test func aReadableRetryDoesNotClearASaveFailureBanner() throws {
        try #require(getuid() != 0, "cannot exercise permission failures as root")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pewter-cause-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "notes.md")

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        _ = store.add(text: "a real note")
        store.flush()

        // Read-only directory: the atomic write's temp file can't be created,
        // while the notes file itself stays perfectly readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        _ = store.add(text: "cannot be written")
        store.flush()
        #expect(storage.health.unreadableCause == nil, "writing broke, not reading")

        store.retryUnavailableStorage()

        let banner = try #require(store.storageBanner, "the save failure must still be on screen")
        #expect(banner.contains("Couldn't save"))
    }

    /// `loadFrom` seeds the mirror from the load and registers for health
    /// *after*, because registration replays the current value: wiring it
    /// first queues the pre-load `.ok` behind the load's verdict, and it lands
    /// second and clears the banner over a file that cannot be read. The
    /// synchronous seed hides that, so this drains the main queue to see it.
    @MainActor
    @Test func theInitialHealthDeliveryCannotClearTheLoadsOwnVerdict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pewter-cause-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)

        let storage = FileStorage.unwatched(fileURL: url)
        let store = ListStore.loadFrom(storage: storage)
        #expect(store.health == .unreadable(cause: .notUTF8))

        // Drained deterministically, not waited out: the assertion is that
        // the mirror does *not* change, and a negative can't be polled for —
        // any clock-based wait either passes early for the wrong reason or
        // spins to its deadline. Registering again queues a delivery behind
        // the store's own on the storage's serial event queue, and both hop
        // to main in order, so by the time this resumes anything that was
        // going to clobber the mirror already has.
        let once = ResumeOnce()
        await withCheckedContinuation { continuation in
            storage.setOnHealthChange { _ in
                DispatchQueue.main.async { once.resume(continuation) }
            }
        }
        #expect(store.health == .unreadable(cause: .notUTF8), "a queued initial `.ok` must not outrank the load")
        #expect(store.health.bannerMessage != nil)
    }

    /// `Data(contentsOf:)` usually surfaces a `CocoaError`, which the `chmod`
    /// test above covers. The `POSIXError` arm exists for the volumes that
    /// report the raw errno instead, and nothing else would notice it being
    /// dead — a bridging assumption is exactly the kind that rots silently.
    @Test func aRawPosixDenialIsAlsoClassifiedAsAPermissionProblem() {
        for code in [EACCES, EPERM] {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            #expect(UnreadableCause(readError: error) == .notPermitted)
        }
        // A different errno must not be swept into the permission arm, or the
        // banner names a repair for something unrelated.
        let unrelated = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        #expect(UnreadableCause(readError: unrelated) != .notPermitted)
    }

    @Test func anUnexpectedFailureKeepsItsDescriptionRatherThanGuessingARemedy() {
        let error = CocoaError(.fileReadCorruptFile)
        let cause = UnreadableCause(readError: error)
        guard case let .other(reason) = cause else {
            Issue.record("expected .other, got \(cause)")
            return
        }
        #expect(!reason.isEmpty)
    }
}

struct HealthBannerTests {
    /// The banner is the only place the user is told what to do about a file
    /// the app has stopped writing to, and it has no other way to name the
    /// repair. One string for every cause would silently drop that
    /// distinction.
    @Test func eachCauseGetsABannerNamingItsOwnRepair() throws {
        #expect(FileStorage.Health.ok.bannerMessage == nil)

        let permission = try #require(FileStorage.Health.unreadable(cause: .notPermitted).bannerMessage)
        #expect(permission.contains("permissions"))

        let encoding = try #require(FileStorage.Health.unreadable(cause: .notUTF8).bannerMessage)
        #expect(encoding.contains("UTF-8"))

        #expect(permission != encoding)
        // Both have to say saving is off, or the banner names a repair without
        // saying why it matters.
        #expect(permission.contains("Saving is off"))
        #expect(encoding.contains("Saving is off"))

        let failed = try #require(FileStorage.Health.saveFailed(reason: "disk full").bannerMessage)
        #expect(failed.contains("disk full"))
    }
}

struct ToastSeverityTests {
    /// The failure this pins: a refusal that costs the user the note they
    /// typed rendering in the same chrome as the toast confirming one landed.
    @Test func everySeverityIsDistinguishableWithoutColour() {
        let symbols = ToastSeverity.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }

    /// Pinned the same way `CaptureFeedbackTests` pins the HUD: the mapping
    /// from meaning to chrome is what keeps a refusal from rendering as a
    /// confirmation, and a silent edit to it is invisible everywhere else.
    @Test func everySeverityPinsItsSymbolAndDuration() {
        #expect(ToastSeverity.confirmation.symbolName == "checkmark.circle.fill")
        #expect(ToastSeverity.confirmation.duration == .seconds(2))

        #expect(ToastSeverity.warning.symbolName == "exclamationmark.circle.fill")
        #expect(ToastSeverity.warning.duration == .seconds(3))

        #expect(ToastSeverity.refusal.symbolName == "exclamationmark.triangle.fill")
        #expect(ToastSeverity.refusal.duration == .seconds(4))
    }

    /// A refusal is an instruction to read and act on; a confirmation has been
    /// absorbed by the time it fades.
    @Test func aRefusalOutlastsAConfirmation() {
        #expect(ToastSeverity.refusal.duration > ToastSeverity.confirmation.duration)
        #expect(ToastSeverity.warning.duration > ToastSeverity.confirmation.duration)
    }
}

struct UnavailabilityMessageTests {
    /// Same requirement as the capture HUD's, on the surface the user is
    /// looking at: the composer's refusal has to name which repair applies.
    @Test func everyRefusalNamesItsOwnRemedy() {
        let messages: [Unavailability] = [
            .unreadable(cause: .notPermitted),
            .unreadable(cause: .notUTF8),
            .unreadable(cause: .other("disk on fire")),
            .adoptionInFlight,
        ]
        let rendered = messages.map(\.refusalMessage)
        #expect(Set(rendered).count == rendered.count)
        #expect(rendered.allSatisfy { !$0.isEmpty })
        // The handoff window is the one that must not read as a broken file.
        #expect(!Unavailability.adoptionInFlight.refusalMessage.contains("can't be read"))
    }
}
