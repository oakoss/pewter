import AppKit
import Observation
import PewterCore

/// Owns the settings window's single recording session: one local key
/// monitor, one active slot. Centralized (rather than per-recorder view
/// state) so starting a second recorder cancels the first, and a closing
/// window can cancel from outside the view tree — an orphaned monitor
/// would swallow every keystroke in the app. Decisions about a pressed
/// chord live in Core's RecorderArbiter; live-trigger state lives in the
/// coordinator.
@MainActor
@Observable
final class KeyRecorderModel {
    private(set) var active: HotKeySlot?
    private(set) var hints: [HotKeySlot: String] = [:]
    private(set) var chords: [HotKeySlot: KeyChord] = [:]

    private var monitor: Any?
    private let coordinator: HotKeyCoordinating

    init(coordinator: HotKeyCoordinating) {
        self.coordinator = coordinator
        refreshChords()
    }

    /// Re-reads stored chords and drops stale hints; called on every window
    /// show because launch-time arming can revert a setting behind the UI.
    func refresh() {
        refreshChords()
        hints = [:]
    }

    func begin(_ slot: HotKeySlot) {
        cancel()
        hints[slot] = nil
        active = slot
        coordinator.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            // Swallow every keystroke while recording.
            return nil
        }
    }

    /// Ends recording without a pick — Esc, the other recorder starting, or
    /// the window closing or losing key.
    func cancel() {
        guard active != nil else { return }
        tearDown()
        noteFailures(coordinator.endRecording())
        refreshChords()
    }

    func clear(_ slot: HotKeySlot) {
        hints[slot] = nil
        coordinator.clear(slot)
        refreshChords()
    }

    private func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        active = nil
    }

    private func handle(_ event: NSEvent) {
        guard let slot = active else { return }
        switch RecorderArbiter.decide(KeyChord(keyDown: event), for: slot, assignments: chords) {
        case .cancel:
            cancel()
        case let .reject(hint):
            hints[slot] = hint
        case let .assign(chord):
            tearDown()
            noteFailures(coordinator.endRecording())
            hints[slot] = coordinator.assign(chord, to: slot)
            // An endRecording failure may have cleared a stored chord; the
            // badge must never show one no longer stored or registered.
            refreshChords()
        }
    }

    /// A chord claimed by another app while it was deliberately
    /// unregistered for recording comes back refused; the badge flips to
    /// Off and this explains why, where the user is looking.
    private func noteFailures(_ failed: Set<HotKeySlot>) {
        for slot in failed {
            hints[slot] = "Another app claimed this shortcut — it was turned off"
        }
    }

    private func refreshChords() {
        var current: [HotKeySlot: KeyChord] = [:]
        for slot in HotKeySlot.allCases {
            current[slot] = coordinator.chord(for: slot)
        }
        chords = current
    }
}
