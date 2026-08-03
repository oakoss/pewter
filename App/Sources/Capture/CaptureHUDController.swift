import AppKit
import os
import PewterCore
import SwiftUI

/// Transient capture feedback at the point of capture. The gesture fires
/// while the user reads some other app, so the confirmation lands where
/// they're looking and fades without stealing focus or opening the panel.
/// VoiceOver feedback stays on the status-item flash, whose image names the
/// same outcome.
@MainActor
final class CaptureHUDController {
    private static let logger = Logger.capture

    enum Feedback {
        case captured
        case nothingSelected
        case captureFailed

        var symbolName: String {
            switch self {
            case .captured: "checkmark.circle"
            case .nothingSelected: "xmark.circle"
            case .captureFailed: "exclamationmark.circle"
            }
        }

        var message: String {
            switch self {
            case .captured: "Captured"
            case .nothingSelected: "No text selected"
            case .captureFailed: "Couldn't capture — try copying manually"
            }
        }

        /// Failure text is an instruction the user has to read and act on;
        /// it stays up longer than the success confirmation.
        var duration: TimeInterval {
            switch self {
            case .captured: 1.2
            case .nothingSelected, .captureFailed: 2
            }
        }
    }

    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?
    /// Ties each fade-out to the show that scheduled it: a stale fade's
    /// completion must not order out a HUD a newer show just put up.
    private var generation = 0

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // VoiceOver feedback is the status-item flash; announcing this
        // window appearing on every capture would double up.
        panel.setAccessibilityElement(false)
    }

    isolated deinit {
        dismissTask?.cancel()
    }

    func show(_ feedback: Feedback) {
        // A failed capture often means an unresponsive frontmost app —
        // asking it for bounds again would stall this feedback for the AX
        // timeout. Anchor failure on the mouse directly.
        let selectionAnchor = feedback == .captureFailed ? nil : SelectionReader().selectionBounds()
        let anchor = selectionAnchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screens = NSScreen.screens
        let screen = CaptureHUDPlacement.screenIndex(for: anchor, in: screens.map(\.frame))
            .map { screens[$0] } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            Self.logger.debug("capture HUD skipped: no screen available")
            return
        }

        // Default sizingOptions, unlike the main panel: fittingSize is
        // derived from the constraint propagation they enable, and this
        // fixed-size panel's whole frame comes from it.
        let hosting = NSHostingView(rootView: CaptureHUDView(feedback: feedback))
        let size = hosting.fittingSize
        panel.contentView = hosting
        panel.setFrame(
            CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: visible),
            display: false
        )

        dismissTask?.cancel()
        generation += 1
        let shown = generation
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(feedback.duration))
            guard !Task.isCancelled, let self, generation == shown else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // AppKit invokes this on the main thread but types it
                // nonisolated; assumeIsolated keeps strict concurrency
                // honest without hopping actors.
                MainActor.assumeIsolated {
                    guard let self, self.generation == shown else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
    }
}

private struct CaptureHUDView: View {
    let feedback: CaptureHUDController.Feedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.symbolName)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
            .padding(2)
    }
}
