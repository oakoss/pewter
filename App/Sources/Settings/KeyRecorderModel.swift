import AppKit
import Observation
import PewterCore

/// Owns the settings window's single recording session: one local key
/// monitor, one active target, one suspend/resume of the live hotkeys.
/// Centralized (rather than per-recorder view state) so starting a second
/// recorder cancels the first, and a closing window can cancel from
/// outside the view tree — an orphaned monitor would swallow every
/// keystroke in the app.
@MainActor
@Observable
final class KeyRecorderModel {
    enum Target {
        case capture, panelToggle
    }

    private(set) var active: Target?
    private(set) var hints: [Target: String] = [:]
    private(set) var captureChord = CaptureSettings.captureChord
    private(set) var toggleChord = PanelSettings.toggleChord

    private var monitor: Any?
    private let actions: SettingsActions

    init(actions: SettingsActions) {
        self.actions = actions
    }

    func chord(for target: Target) -> KeyChord? {
        target == .capture ? captureChord : toggleChord
    }

    /// Re-reads stored chords and drops stale hints; called on every window
    /// show because launch-time arming can revert a setting behind the UI.
    func refresh() {
        captureChord = CaptureSettings.captureChord
        toggleChord = PanelSettings.toggleChord
        hints = [:]
    }

    func begin(_ target: Target) {
        cancel()
        hints[target] = nil
        active = target
        actions.suspendHotKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            // Swallow every keystroke while recording.
            return nil
        }
    }

    /// Ends recording without a pick — Esc, the other recorder starting, or
    /// the window closing.
    func cancel() {
        guard active != nil else { return }
        tearDown()
        noteResumeFailures(actions.resumeHotKeys())
        refreshChords()
    }

    func clear(_ target: Target) {
        hints[target] = nil
        apply(nil, to: target)
    }

    private func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        active = nil
    }

    private func handle(_ event: NSEvent) {
        guard let target = active else { return }
        // Bare Escape cancels the recording, mirroring the system recorder;
        // Esc with a chording modifier is a recordable pick.
        if event.keyCode == 53,
           event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
        {
            cancel()
            return
        }
        let picked = KeyChord(keyDown: event)
        guard picked.isValidGlobalHotKey else {
            hints[target] = "Include ⌃, ⌥, or ⌘ — a bare key would shadow normal typing"
            return
        }
        guard !picked.isSystemReserved else {
            hints[target] = "\(picked.display) would shadow a standard shortcut — add another modifier"
            return
        }
        tearDown()
        noteResumeFailures(actions.resumeHotKeys())
        apply(picked, to: target)
    }

    /// A chord claimed by another app while it was deliberately
    /// unregistered for recording comes back refused; the badge flips to
    /// Off and this explains why, where the user is looking.
    private func noteResumeFailures(_ result: (captureOK: Bool, toggleOK: Bool)) {
        if !result.captureOK {
            hints[.capture] = "Another app claimed this shortcut — it was turned off"
        }
        if !result.toggleOK {
            hints[.panelToggle] = "Another app claimed this shortcut — it was turned off"
        }
    }

    private func apply(_ chord: KeyChord?, to target: Target) {
        // Unconditional: a resume failure may have nilled a stored chord,
        // and even the early-return conflict path must not leave the badge
        // showing a chord that is no longer stored or registered.
        defer { refreshChords() }
        // The two shortcuts registering the same chord would fail with a
        // misleading "taken by another app" — that app being us.
        if let chord {
            let conflict = switch target {
            case .capture: chord == PanelSettings.toggleChord
            case .panelToggle: chord == CaptureSettings.captureChord
            }
            if conflict {
                hints[target] = target == .capture
                    ? "Already used by Show or hide panel"
                    : "Already used by Capture selection"
                return
            }
        }
        hints[target] = switch target {
        case .capture: actions.applyCaptureChord(chord)
        case .panelToggle: actions.applyToggleChord(chord)
        }
    }

    private func refreshChords() {
        captureChord = CaptureSettings.captureChord
        toggleChord = PanelSettings.toggleChord
    }
}
