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
            onShowPermissions: { [weak self] in
                self?.onboarding?.show()
            },
            onSelectTapModifier: { [weak self] modifier in
                CaptureSettings.tapModifier = modifier
                self?.applyCaptureTriggers()
            },
            onSelectChordHotKey: { [weak self] chord in
                CaptureSettings.chordHotKey = chord
                self?.applyCaptureTriggers()
            },
            onSelectToggleHotKey: { [weak self] hotKey in
                PanelSettings.toggleHotKey = hotKey
                self?.applyPanelToggleHotKey()
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
            self.panelController?.toggle(relativeTo: self.statusItemController?.button)
        }

        let onboarding = OnboardingWindowController(permission: permission)
        self.onboarding = onboarding

        uiState.showsPermissionBanner = !permission.isTrusted
        uiState.onRequestPermission = { [weak onboarding] in
            onboarding?.showIfNeeded()
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

        if permission?.isTrusted == true {
            tapMonitor?.start(target: CaptureSettings.tapModifier.flag)
        } else {
            tapMonitor?.stop()
        }

        if hotKeyCenter?.arm(.capture, chord: CaptureSettings.chordHotKey.chord) == .failed {
            CaptureSettings.chordHotKey = .off
            panelController?.show(relativeTo: statusItemController?.button)
            uiState.showToast("Couldn't set up the hotkey — it may be in use by another app")
        }
    }

    /// (Re)arms the panel toggle hotkey; permission-free, so always armed.
    private func applyPanelToggleHotKey() {
        if hotKeyCenter?.arm(.panelToggle, chord: PanelSettings.toggleHotKey.chord) == .failed {
            PanelSettings.toggleHotKey = .off
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
            panelController?.show(relativeTo: statusItemController?.button)
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
