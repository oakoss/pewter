import Accessibility
import Foundation
import Observation
import PewterCore

/// Transient UI signals the capture pipeline sends into the panel.
@MainActor
@Observable
final class PanelUIState {
    /// Search filter. Lives here rather than in view @State so the capture
    /// path can clear it — a capture landing behind an active filter is
    /// invisible and reads as a failed capture.
    var query = ""

    /// A toast and what it means. Paired so the two can't be set apart and
    /// drift — a refusal rendered in confirmation chrome is the failure this
    /// exists to prevent.
    struct Toast: Equatable {
        let message: String
        let severity: ToastSeverity
    }

    /// Set only through `showToast`: a direct write would skip the
    /// announcement and the dismiss timer, leaving a toast up for good.
    private(set) var toast: Toast?
    var highlightedItemID: UUID?
    var showsPermissionBanner = false
    /// Empty-state hint reflecting the configured capture trigger.
    var captureHint = "Double-tap Shift to capture a selection"
    var onRequestPermission: (() -> Void)?
    /// Cmd+W — the view can't reach the panel window, so hiding routes out
    /// through a closure seam.
    var onDismissPanel: (() -> Void)?

    /// Bumped by `reveal(_:)`; the list scrolls on its change, so the scroll
    /// is tied to the request itself rather than a list-count change that
    /// may or may not accompany it.
    private(set) var revealToken = 0
    /// Scroll target for the current token. Deliberately not cleared by the
    /// flash timer: a hidden panel may not process the token change until
    /// the next summon, and the scroll must still land then.
    private(set) var revealTargetID: UUID?

    private var toastTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?

    /// Points the user at an item: flashes it and scrolls it into view.
    /// Scrolling a filtered-out or not-yet-rendered id is a no-op.
    func reveal(_ id: UUID, for duration: Duration = .seconds(1)) {
        revealToken += 1
        revealTargetID = id
        highlightedItemID = id
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.highlightedItemID = nil
        }
    }

    /// `announces: false` is for callers that already announced the same
    /// message on another surface (the status-item flash) — one outcome
    /// must not be spoken twice.
    func showToast(_ message: String, severity: ToastSeverity, announces: Bool = true) {
        toast = Toast(message: message, severity: severity)
        if announces {
            AccessibilityNotification.Announcement(message).post()
        }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: severity.duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
