import AppKit
import os
import PewterCore
import SwiftUI

/// Transient capture feedback at the point of capture. The gesture fires
/// while the user reads some other app, so the confirmation lands where
/// they're looking and fades without stealing focus or opening the panel.
/// Purely visual: VoiceOver users get the outcome from `CaptureSound`,
/// since macOS won't speak announcements from a background app.
@MainActor
final class CaptureHUDController {
    private static let logger = Logger.capture

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
        // Decoration for sighted users; CaptureSound carries the outcome
        // to VoiceOver, so there is nothing here worth announcing.
        panel.setAccessibilityElement(false)
    }

    isolated deinit {
        dismissTask?.cancel()
    }

    /// `anchor` comes from the capture's own AX read, carried on the
    /// outcome; nil (pasteboard captures, failures) anchors on the mouse.
    func show(_ feedback: CaptureFeedback, anchor selectionAnchor: CGRect?) {
        let anchor = selectionAnchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screens = NSScreen.screens
        let screen = ScreenGeometry.screenIndex(for: anchor, in: screens.map(\.frame))
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
            // Cancellation alone guards this body — a newer show cancels
            // before it can fade the wrong HUD.
            try? await Task.sleep(for: .seconds(feedback.duration))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: {
                // AppKit invokes this on the main thread but types it
                // nonisolated; assumeIsolated keeps strict concurrency
                // honest without hopping actors. The generation check is
                // load-bearing only here: the completion isn't cancellable,
                // and a stale fade's completion must not order out a HUD a
                // newer show has since put up.
                MainActor.assumeIsolated {
                    guard self.generation == shown else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
    }
}

private struct CaptureHUDView: View {
    let feedback: CaptureFeedback

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
