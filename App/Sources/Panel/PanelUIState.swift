import Foundation
import Observation

/// Transient UI signals the capture pipeline sends into the panel.
@MainActor
@Observable
final class PanelUIState {
    /// Search filter. Lives here rather than in view @State so the capture
    /// path can clear it — a capture landing behind an active filter is
    /// invisible and reads as a failed capture.
    var query = ""
    var toast: String?
    var highlightedItemID: UUID?
    var showsPermissionBanner = false
    /// Persistent storage-failure banner; unlike toasts these usually repeat.
    var storageError: String?
    /// Empty-state hint reflecting the configured capture trigger.
    var captureHint = "Double-tap Shift to capture a selection"
    var onRequestPermission: (() -> Void)?
    /// Launcher actions for the panel's ellipsis menu — the mouse path for
    /// users who never discover the status item's right-click menu.
    var onOpenSettings: (() -> Void)?
    var onRevealNotesFile: (() -> Void)?
    /// Unconditional, unlike onRequestPermission's showIfNeeded — a menu
    /// item must open the window even when access is already granted.
    var onShowPermissions: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    /// Cmd+W — the view can't reach the panel window, so hiding routes out
    /// through the same closure seam as the launcher actions.
    var onDismissPanel: (() -> Void)?

    /// One-shot scroll request, consumed by the next list-count change —
    /// unlike the 1 s highlight, it can't retarget a later, unrelated change.
    private var scrollTargetID: UUID?

    private var toastTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?

    func requestScroll(to id: UUID) {
        scrollTargetID = id
    }

    func takeScrollTarget() -> UUID? {
        defer { scrollTargetID = nil }
        return scrollTargetID
    }

    func showToast(_ message: String, for duration: Duration = .seconds(2)) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func highlight(_ id: UUID, for duration: Duration = .seconds(1)) {
        highlightedItemID = id
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.highlightedItemID = nil
        }
    }
}
