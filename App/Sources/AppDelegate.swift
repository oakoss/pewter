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
    private var hotKeyCoordinator: HotKeyCoordinator?
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

        let hotKeyCoordinator = HotKeyCoordinator(
            arm: { [weak hotKeyCenter] slot, chord in
                hotKeyCenter?.arm(slot, chord: chord?.carbonChord) != .failed
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
            self?.hotKeyCoordinator?.syncTriggers()
            self?.uiState.showsPermissionBanner = false
        }
        permission.onRevoked = { [weak self] in
            self?.hotKeyCoordinator?.syncTriggers()
            self?.uiState.showsPermissionBanner = true
        }

        toastArmingFailures(hotKeyCoordinator.syncTriggers())
        if !permission.isTrusted {
            onboarding.showIfNeeded()
        }
    }

    /// Launch-time arming is the only toast path — everywhere else a
    /// refusal renders as a recorder hint in the settings window.
    private func toastArmingFailures(_ failed: Set<HotKeySlot>) {
        guard !failed.isEmpty else { return }
        panelController?.show(relativeTo: statusItemController?.button)
        for slot in HotKeySlot.allCases where failed.contains(slot) {
            uiState.showToast(slot.armingFailureMessage)
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
