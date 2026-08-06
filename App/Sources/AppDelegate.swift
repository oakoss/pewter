import AppKit
import PewterCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ListStore?
    private var panelController: PanelController?
    private var statusItemController: StatusItemController?
    private var permission: AccessibilityPermission?
    private var tapMonitor: ModifierTapMonitor?
    private var hotKeyCenter: HotKeyCenter?
    private var captureCoordinator: CaptureCoordinator?
    private var onboarding: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var hotKeyCoordinator: HotKeyCoordinator?
    private var clipboardTracker: ClipboardActivityTracker?
    private var captureHUD: CaptureHUDController?
    private let uiState = PanelUIState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kept alive by the store, which holds it strongly; the reveal command
        // below captures it for its URL.
        let storage = FileStorage(fileURL: FileStorage.defaultURL())
        let store = ListStore.loadFrom(storage: storage)
        self.store = store

        let permission = AccessibilityPermission()
        self.permission = permission

        let commands = AppCommands(
            revealNotesFile: {
                NSWorkspace.shared.activateFileViewerSelecting([storage.fileURL])
            },
            settings: { [weak self] in
                self?.showSettings()
            },
            permissions: { [weak self] in
                self?.onboarding?.show()
            },
            copyDiagnostics: { [weak self] in
                self?.copyDiagnostics()
            },
            quit: {
                NSApp.terminate(nil)
            }
        )

        let panelController = PanelController(
            rootView: PanelRootView(commands: commands)
                .environment(store)
                .environment(uiState),
            onWillShow: { [weak store] in store?.retryUnavailableStorage() }
        )
        self.panelController = panelController

        let statusItemController = StatusItemController(
            onToggle: { button in
                panelController.toggle(relativeTo: button)
            },
            commands: commands
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
                // Poll the tracker first — it advances its change baseline —
                // then deny the assist for browsers: it exists for
                // copy-on-select TUIs, and honoring it in a browser would
                // store stale clipboard content instead of falling through
                // to the AX rescue.
                let recent = clipboardTracker?.changedRecently(within: 3) ?? false
                return recent && !RichSourceApps.frontmostIsRichSource()
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
            isTrusted: { AXIsProcessTrusted() },
            prefersRichSource: { RichSourceApps.frontmostIsRichSource() }
        )
        captureCoordinator = coordinator
        coordinator.onOutcome = { [weak self] outcome in
            self?.handleCapture(outcome)
        }
        captureHUD = CaptureHUDController()

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

        let hotKeyCoordinator = HotKeyCoordinator(
            // Strong capture, deliberately: both objects live for the
            // process, there is no back-reference, and a weak capture would
            // report "armed" for a vanished center.
            arm: { slot, chord in
                hotKeyCenter.arm(slot, chord: chord?.carbonChord) != .failed
            },
            setTapActive: { [weak self] active in
                guard let self else { return }
                // The hint tracks the configured gesture; setting it here
                // keeps every gesture-derived output inside the resync.
                uiState.captureHint = CaptureSettings.tapModifier.hint
                if active, self.permission?.isTrusted == true {
                    self.tapMonitor?.start(target: CaptureSettings.tapModifier.flag)
                } else {
                    self.tapMonitor?.stop()
                }
            }
        )
        self.hotKeyCoordinator = hotKeyCoordinator

        let onboarding = OnboardingWindowController(permission: permission)
        self.onboarding = onboarding

        uiState.showsPermissionBanner = !permission.isTrusted
        uiState.onRequestPermission = { [weak onboarding] in
            onboarding?.showIfNeeded()
        }
        uiState.onDismissPanel = { [weak panelController] in
            panelController?.hide()
        }

        permission.onGranted = { [weak self] in
            self?.hotKeyCoordinator?.syncTriggers()
            self?.uiState.showsPermissionBanner = false
            self?.onboarding?.clearDeclined()
        }
        permission.onRevoked = { [weak self] in
            self?.hotKeyCoordinator?.syncTriggers()
            self?.uiState.showsPermissionBanner = true
        }

        toastArmingFailures(hotKeyCoordinator.syncTriggers())
        onboarding.showAtLaunchIfNeeded()
    }

    /// Launch-time arming is the only toast path — everywhere else a
    /// refusal renders as a recorder hint in the settings window.
    private func toastArmingFailures(_ failed: Set<HotKeySlot>) {
        guard !failed.isEmpty else { return }
        panelController?.show(relativeTo: statusItemController?.button)
        for slot in HotKeySlot.allCases where failed.contains(slot) {
            // A warning, not a refusal: a trigger that wouldn't arm costs the
            // user a shortcut, not anything they had typed.
            uiState.showToast(slot.armingFailureMessage, severity: .warning)
        }
    }

    func showSettings() {
        if settingsController == nil, let hotKeyCoordinator {
            settingsController = SettingsWindowController(coordinator: hotKeyCoordinator)
        }
        settingsController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
    }

    private func copyDiagnostics() {
        Task { [weak self] in
            let outcome = await Diagnostics.copyReport()
            guard let self else { return }
            // Flash description and toast state the same clipboard outcome —
            // a VoiceOver user on the status-item path and a sighted user
            // watching the panel must not hear different stories.
            let (symbol, message, duration, severity): (String, String, TimeInterval, ToastSeverity) = switch outcome {
            case .copied:
                ("doc.on.clipboard", "Diagnostics copied", 0.8, .confirmation)
            case .errorCopied:
                ("exclamationmark.circle", "Couldn't read logs — error copied", 2, .warning)
            case .failed:
                ("exclamationmark.circle", "Couldn't copy diagnostics", 2, .warning)
            }
            statusItemController?.flash(symbolName: symbol, description: message, duration: duration)
            if panelController?.isVisible == true {
                // The flash already announced this exact message.
                uiState.showToast(message, severity: severity, announces: false)
            }
        }
    }

    private func handleCapture(_ outcome: CaptureCoordinator.Outcome) {
        switch outcome {
        case let .captured(item, anchor):
            if panelController?.isVisible == true {
                // An active filter would hide the new item and the capture
                // would read as failed. A hidden panel keeps its filter —
                // the HUD already confirmed the capture.
                uiState.query = ""
            }
            // Unconditional: a visible list lands on the new note, and a
            // hidden panel keeps the target so the scroll lands on the
            // next summon. A filtered-out id scrolls nowhere.
            uiState.reveal(item.id)
            showCaptureFeedback(.captured, anchor: anchor)
        case let .nothingSelected(anchor):
            showCaptureFeedback(.nothingSelected, anchor: anchor)
        case .captureFailed:
            showCaptureFeedback(.captureFailed, anchor: nil)
        case let .notesUnavailable(reason):
            showCaptureFeedback(.notesUnavailable(reason), anchor: nil)
        case .notPermitted:
            onboarding?.showIfNeeded()
        }
    }

    private func showCaptureFeedback(_ feedback: CaptureFeedback, anchor: CGRect?) {
        captureHUD?.show(feedback, anchor: anchor)
        // The other two surfaces are silent for a VoiceOver user
        // mid-capture: the HUD is visual, and macOS drops the flash's
        // announcement because the source app, not Pewter, is frontmost.
        CaptureSound.play(feedback)
        statusItemController?.flash(
            symbolName: feedback.symbolName,
            description: feedback.message,
            duration: feedback.duration
        )
    }
}
