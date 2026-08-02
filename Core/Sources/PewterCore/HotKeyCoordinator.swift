import Foundation
import os

/// Seam between the recorder UI and the live trigger state, so the model
/// can be exercised against a fake.
@MainActor
public protocol HotKeyCoordinating: AnyObject {
    func beginRecording()
    /// Ends recording and resyncs; returns the slots the OS refused (their
    /// stored chords are cleared — nothing may display as armed while
    /// unregistered).
    func endRecording() -> Set<HotKeySlot>
    /// Persists and arms; on refusal restores the previous chord and
    /// returns a user-facing error. Callers only reach this outside a
    /// recording session — turning a shortcut off mid-session goes through
    /// `clear`, which is the only mutation that is recording-safe.
    func assign(_ chord: KeyChord, to slot: HotKeySlot) -> String?
    func clear(_ slot: HotKeySlot)
    func chord(for slot: HotKeySlot) -> KeyChord?
    @discardableResult
    func syncTriggers() -> Set<HotKeySlot>
}

/// The hotkey/tap-trigger state machine. Armed state is always *derived*
/// from (isRecording, stored chords) by one idempotent resync — never
/// toggled — so no path can leave the triggers half-suspended, and pressing
/// the currently assigned chord while recording records instead of firing.
/// AppKit-free: the OS touches (Carbon registration, tap monitor) come in
/// as closures, which is what makes the rollback logic testable.
@MainActor
public final class HotKeyCoordinator: HotKeyCoordinating {
    /// Returns false only when the OS refused the registration.
    private let arm: (HotKeySlot, KeyChord?) -> Bool
    /// Starts or stops the double-tap monitor; the closure owns the
    /// permission check and the current modifier choice.
    private let setTapActive: (Bool) -> Void
    private let defaults: UserDefaults

    public private(set) var isRecording = false

    public init(
        defaults: UserDefaults = .standard,
        arm: @escaping (HotKeySlot, KeyChord?) -> Bool,
        setTapActive: @escaping (Bool) -> Void
    ) {
        self.defaults = defaults
        self.arm = arm
        self.setTapActive = setTapActive
    }

    public func beginRecording() {
        isRecording = true
        syncTriggers()
    }

    public func endRecording() -> Set<HotKeySlot> {
        isRecording = false
        return syncTriggers()
    }

    /// Converges the live triggers on the desired state. Cheap to call from
    /// every path (launch, permission change, gesture change, recording
    /// boundaries): re-arming an unchanged chord is a no-op downstream.
    @discardableResult
    public func syncTriggers() -> Set<HotKeySlot> {
        setTapActive(!isRecording)
        var failed: Set<HotKeySlot> = []
        for slot in HotKeySlot.allCases {
            let desired = isRecording ? nil : slot.chord(in: defaults)
            if !arm(slot, desired) {
                // The common "my shortcut turned itself off" path — some
                // callers surface no UI for it, so the log is the record.
                Logger.hotkey.error("\(slot.title, privacy: .public) failed to arm; stored shortcut cleared")
                slot.setChord(nil, in: defaults)
                failed.insert(slot)
            }
        }
        return failed
    }

    public func assign(_ chord: KeyChord, to slot: HotKeySlot) -> String? {
        let previous = slot.chord(in: defaults)
        slot.setChord(chord, in: defaults)
        if arm(slot, chord) {
            Logger.hotkey.info("assigned \(chord.display, privacy: .public) to \(slot.title, privacy: .public)")
            return nil
        }
        Logger.hotkey.info("\(chord.display, privacy: .public) refused for \(slot.title, privacy: .public)")
        slot.setChord(previous, in: defaults)
        // The slot is disarmed after a refusal, so this is a real
        // registration attempt; a stored chord must never display as
        // active while nothing is registered.
        if arm(slot, previous) {
            return "That shortcut is taken by another app"
        }
        // The user's previously working chord is gone — the hint saying so
        // is transient, so the durable record is this line.
        Logger.hotkey
            .error(
                "previous \(previous?.display ?? "off", privacy: .public) also refused for \(slot.title, privacy: .public); shortcut cleared"
            )
        slot.setChord(nil, in: defaults)
        return "That shortcut is taken — and another app claimed the previous one too"
    }

    public func clear(_ slot: HotKeySlot) {
        Logger.hotkey.info("cleared the \(slot.title, privacy: .public) shortcut")
        slot.setChord(nil, in: defaults)
        // Disarming cannot be refused; while recording the slot is already
        // disarmed and the endRecording resync makes it stick.
        if !isRecording {
            _ = arm(slot, nil)
        }
    }

    public func chord(for slot: HotKeySlot) -> KeyChord? {
        slot.chord(in: defaults)
    }
}
