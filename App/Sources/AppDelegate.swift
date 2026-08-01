import AppKit
import PewterCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ListStore?
    private var storage: FileStorage?
    private var panelController: PanelController?
    private var statusItemController: StatusItemController?
    private var permission: AccessibilityPermission?
    private var tapMonitor: ModifierTapMonitor?
    private var hotKeyCenter: HotKeyCenter?
    private var captureCoordinator: CaptureCoordinator?
    private var onboarding: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    /// True while a shortcut recording is active: arming paths triggered
    /// from elsewhere (the permission poll, the gesture picker) must not
    /// silently undo the suspend.
    private var hotKeysSuspended = false
    private var clipboardTracker: ClipboardActivityTracker?
    private let uiState = PanelUIState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let storage = FileStorage(fileURL: FileStorage.defaultURL())
        let store = ListStore.loadFrom(storage: storage)
        self.storage = storage
        self.store = store

        let permission = AccessibilityPermission()
        self.permission = permission

        let panelController = PanelController(
            rootView: PanelRootView()
                .environment(store)
                .environment(uiState)
        )
        self.panelController = panelController

        let statusItemController = StatusItemController(
            onToggle: { button in
                panelController.toggle(relativeTo: button)
            },
            onRevealFile: {
                NSWorkspace.shared.activateFileViewerSelecting([storage.fileURL])
            },
            onShowSettings: { [weak self] in
                self?.showSettings()
            },
            onShowPermissions: { [weak self] in
                self?.onboarding?.show()
            }
        )
        self.statusItemController = statusItemController

        let clipboardTracker = ClipboardActivityTracker()
        self.clipboardTracker = clipboardTracker
        Pasteboard.beginOwnWrite = { [weak clipboardTracker] in
            clipboardTracker?.beginOwnWrites()
        }
        Pasteboard.endOwnWrite = { [weak clipboardTracker] in
            clipboardTracker?.endOwnWrites()
        }

        let pasteboardCapture = PasteboardCapture(
            recentClipboardChange: { [weak clipboardTracker] in
                clipboardTracker?.changedRecently(within: 3) ?? false
            },
            beginOwnWrites: { [weak clipboardTracker] in
                clipboardTracker?.beginOwnWrites()
            },
            endOwnWrites: { [weak clipboardTracker] in
                clipboardTracker?.endOwnWrites()
            }
        )

        let coordinator = CaptureCoordinator(
            store: store,
            selectionReader: SelectionReader(),
            pasteboardCapture: pasteboardCapture,
            isTrusted: { AXIsProcessTrusted() }
        )
        captureCoordinator = coordinator
        coordinator.onOutcome = { [weak self] outcome in
            self?.handleCapture(outcome)
        }

        let tapMonitor = ModifierTapMonitor()
        self.tapMonitor = tapMonitor
        tapMonitor.onDoubleTap = { [weak coordinator] in
            coordinator?.captureSelection()
        }

        let hotKeyCenter = HotKeyCenter()
        self.hotKeyCenter = hotKeyCenter
        hotKeyCenter.setHandler(for: .capture) { [weak coordinator] in
            coordinator?.captureSelection()
        }
        hotKeyCenter.setHandler(for: .panelToggle) { [weak self] in
            guard let self else { return }
            self.panelController?.toggle(relativeTo: self.statusItemController?.button, onActiveScreen: true)
        }

        let onboarding = OnboardingWindowController(permission: permission)
        self.onboarding = onboarding

        uiState.showsPermissionBanner = !permission.isTrusted
        uiState.onRequestPermission = { [weak onboarding] in
            onboarding?.showIfNeeded()
        }
        uiState.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        uiState.onRevealNotesFile = {
            NSWorkspace.shared.activateFileViewerSelecting([storage.fileURL])
        }
        uiState.onShowPermissions = { [weak onboarding] in
            onboarding?.show()
        }

        if storage.savesSuspended {
            uiState.storageError = "Notes file can't be read — saving is off to protect it"
        }
        storage.setOnStorageEvent { [weak self] event in
            // DispatchQueue.main is FIFO; unstructured Tasks are not, and
            // these events swapping order would render the wrong banner
            // (e.g. saveSucceeded clearing a still-live protection banner).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch event {
                    case let .saveFailed(reason):
                        self.uiState.storageError = "Couldn't save your notes — \(reason)"
                    case .saveSucceeded, .recovered:
                        self.uiState.storageError = nil
                    case .protectedUnreadable:
                        self.uiState.storageError = "Notes file can't be read — saving is off to protect it"
                    }
                }
            }
        }

        permission.onGranted = { [weak self] in
            self?.applyCaptureTriggers()
            self?.uiState.showsPermissionBanner = false
        }
        permission.onRevoked = { [weak self] in
            self?.tapMonitor?.stop()
            self?.uiState.showsPermissionBanner = true
        }

        applyCaptureTriggers()
        applyPanelToggleHotKey()
        if !permission.isTrusted {
            onboarding.showIfNeeded()
        }
    }

    /// (Re)arms both capture triggers from settings. The chord hotkey needs
    /// no permissions, so it's always armed; the tap monitor needs the
    /// Accessibility grant.
    private func applyCaptureTriggers() {
        uiState.captureHint = CaptureSettings.tapModifier.hint
        guard !hotKeysSuspended else { return }

        if permission?.isTrusted == true {
            tapMonitor?.start(target: CaptureSettings.tapModifier.flag)
        } else {
            tapMonitor?.stop()
        }

        if !armCaptureFromSettings() {
            panelController?.show(relativeTo: statusItemController?.button)
            uiState.showToast("Couldn't set up the capture hotkey — it may be in use by another app")
        }
    }

    private func armCaptureFromSettings() -> Bool {
        guard hotKeyCenter?.arm(.capture, chord: CaptureSettings.captureChord?.carbonChord) == .failed else {
            return true
        }
        CaptureSettings.captureChord = nil
        return false
    }

    private func armToggleFromSettings() -> Bool {
        guard hotKeyCenter?.arm(.panelToggle, chord: PanelSettings.toggleChord?.carbonChord) == .failed else {
            return true
        }
        PanelSettings.toggleChord = nil
        return false
    }

    /// Single writer for a recorded chord: persists, arms, and on refusal
    /// restores the previous working chord — one mistyped conflict must not
    /// destroy a good shortcut.
    private func setCaptureChord(_ chord: KeyChord?) -> String? {
        // Recording resumes before applying its pick; only Turn Off (nil)
        // may arrive while suspended, and arming nil cannot un-suspend.
        assert(!hotKeysSuspended || chord == nil)
        let previous = CaptureSettings.captureChord
        CaptureSettings.captureChord = chord
        guard hotKeyCenter?.arm(.capture, chord: chord?.carbonChord) == .failed else { return nil }
        CaptureSettings.captureChord = previous
        // The id is disarmed after a refusal, so this is a real
        // registration attempt; a stored chord must never display as
        // active while nothing is registered.
        if hotKeyCenter?.arm(.capture, chord: previous?.carbonChord) == .failed {
            CaptureSettings.captureChord = nil
            return "That shortcut is taken — and another app claimed the previous one too"
        }
        return "That shortcut is taken by another app"
    }

    private func setToggleChord(_ chord: KeyChord?) -> String? {
        // Recording resumes before applying its pick; only Turn Off (nil)
        // may arrive while suspended, and arming nil cannot un-suspend.
        assert(!hotKeysSuspended || chord == nil)
        let previous = PanelSettings.toggleChord
        PanelSettings.toggleChord = chord
        guard hotKeyCenter?.arm(.panelToggle, chord: chord?.carbonChord) == .failed else { return nil }
        PanelSettings.toggleChord = previous
        if hotKeyCenter?.arm(.panelToggle, chord: previous?.carbonChord) == .failed {
            PanelSettings.toggleChord = nil
            return "That shortcut is taken — and another app claimed the previous one too"
        }
        return "That shortcut is taken by another app"
    }

    func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(actions: SettingsActions(
                applyCaptureChord: { [weak self] in self?.setCaptureChord($0) },
                applyToggleChord: { [weak self] in self?.setToggleChord($0) },
                applyTapModifier: { [weak self] in self?.applyCaptureTriggers() },
                suspendHotKeys: { [weak self] in
                    guard let self else { return }
                    hotKeysSuspended = true
                    // The double-tap monitor pauses too — fumbling a chord
                    // (tap, release, tap) must not fire a capture over the
                    // settings window.
                    tapMonitor?.stop()
                    _ = hotKeyCenter?.arm(.capture, chord: nil)
                    _ = hotKeyCenter?.arm(.panelToggle, chord: nil)
                },
                resumeHotKeys: { [weak self] in
                    guard let self else { return (true, true) }
                    hotKeysSuspended = false
                    if permission?.isTrusted == true {
                        tapMonitor?.start(target: CaptureSettings.tapModifier.flag)
                    }
                    // Failures surface as recorder hints — the panel toast
                    // isn't visible with the settings window frontmost.
                    return (armCaptureFromSettings(), armToggleFromSettings())
                }
            ))
        }
        settingsController?.show()
    }

    /// (Re)arms the panel toggle hotkey; permission-free, so always armed.
    private func applyPanelToggleHotKey() {
        guard !hotKeysSuspended else { return }
        if !armToggleFromSettings() {
            panelController?.show(relativeTo: statusItemController?.button)
            uiState.showToast("Couldn't set up the panel hotkey — it may be in use by another app")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
    }

    private func handleCapture(_ outcome: CaptureCoordinator.Outcome) {
        switch outcome {
        case let .captured(item):
            // An active filter would hide the new item and the capture would
            // read as failed.
            uiState.query = ""
            // Capture is a keyboard summon from wherever the user works —
            // its feedback must appear on the screen they're looking at.
            panelController?.show(relativeTo: statusItemController?.button, onActiveScreen: true)
            uiState.highlight(item.id)
            statusItemController?.flash(symbolName: "checkmark.circle", description: "Captured")
        case .nothingSelected:
            statusItemController?.flash(symbolName: "xmark.circle", description: "Nothing selected")
            if panelController?.isVisible == true {
                uiState.showToast("No text selected")
            }
        case .captureFailed:
            statusItemController?.flash(symbolName: "exclamationmark.circle", description: "Capture failed")
            if panelController?.isVisible == true {
                uiState.showToast("Couldn't capture — try copying manually")
            }
        case .notPermitted:
            onboarding?.showIfNeeded()
        }
    }
}
