import ApplicationServices
import Observation

/// Tracks the Accessibility (TCC) grant in both directions. There is no
/// notification for the grant changing, so we poll: fast while untrusted
/// (onboarding is waiting), slowly while trusted (to catch revocation, which
/// otherwise kills the event monitors with zero feedback).
@MainActor
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted: Bool
    var onGranted: (() -> Void)?
    var onRevoked: (() -> Void)?

    private var pollTimer: Timer?

    init() {
        isTrusted = AXIsProcessTrusted()
        startPolling()
    }

    /// The run loop retains scheduled timers; without this a released
    /// instance leaves a forever-ticking no-op timer.
    isolated deinit {
        pollTimer?.invalidate()
    }

    /// Shows the system prompt that offers to open System Settings.
    func promptForAccess() {
        // Literal key because the kAXTrustedCheckOptionPrompt global isn't
        // concurrency-safe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let interval: TimeInterval = isTrusted ? 5.0 : 1.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTrust()
            }
        }
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        startPolling()
        if trusted {
            onGranted?()
        } else {
            onRevoked?()
        }
    }
}
