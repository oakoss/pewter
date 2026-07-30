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

    private var toastTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?

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
