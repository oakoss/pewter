import AppKit
import SwiftUI

/// Shown when Accessibility isn't granted yet. This is a normal activating
/// window (unlike the panel) so it lands in front of the user.
@MainActor
final class OnboardingWindowController: NSObject {
    private static let declinedKey = "onboardingDeclined"

    private var window: NSWindow?
    private let permission: AccessibilityPermission

    init(permission: AccessibilityPermission) {
        self.permission = permission
    }

    /// Launch-time variant: a recorded decline suppresses the window, so an
    /// untrusted user who dismissed it once isn't re-prompted every launch —
    /// the panel banner and a capture attempt remain the recovery paths.
    func showAtLaunchIfNeeded() {
        guard !permission.isTrusted else {
            // A grant made while the app wasn't running never fires
            // onGranted; clearing here keeps a later revocation's fresh
            // prompt working.
            clearDeclined()
            return
        }
        guard !UserDefaults.standard.bool(forKey: Self.declinedKey) else { return }
        show()
    }

    func showIfNeeded() {
        guard !permission.isTrusted else { return }
        show()
    }

    /// Unconditional variant for the status menu's Permissions… item — when
    /// trusted it shows the "You're all set" state.
    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: OnboardingView(permission: permission) { [weak self] in
                    self?.close()
                }
            )
            window.center()
            window.delegate = self
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        recordDeclineIfUntrusted()
        window?.orderOut(nil)
    }

    /// Granting resets the ledger — a later revocation is a new state and
    /// earns one fresh launch prompt.
    func clearDeclined() {
        UserDefaults.standard.removeObject(forKey: Self.declinedKey)
    }

    /// Any dismissal while still untrusted counts as the decline — "Later"
    /// and the title-bar close button carry the same intent.
    private func recordDeclineIfUntrusted() {
        guard !permission.isTrusted else { return }
        UserDefaults.standard.set(true, forKey: Self.declinedKey)
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        recordDeclineIfUntrusted()
    }
}

private struct OnboardingView: View {
    @Bindable var permission: AccessibilityPermission
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "hand.raised.circle")
                .font(.system(size: 44))
                .foregroundStyle(permission.isTrusted ? Color.green : Color.accentColor)

            Text(permission.isTrusted ? "You're all set" : "Enable capture")
                .font(.title2.bold())

            if permission.isTrusted {
                // Derived from settings — a user who picked Control must not
                // be told to double-tap Shift.
                Text(CaptureSettings.tapModifier.hint + ".")
                    .multilineTextAlignment(.center)
                Button("Start using Pewter") { onDone() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(
                    """
                    Pewter needs **Accessibility** access for two things: \
                    hearing the double-tap capture shortcut, and reading the \
                    text you've selected when you trigger a capture.

                    Nothing leaves your Mac. No tracking, no account, no network.
                    """
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

                Button("Grant Accessibility Access") {
                    permission.promptForAccess()
                }
                .keyboardShortcut(.defaultAction)

                // The system prompt only appears once per TCC state; after
                // dismissing it this is the recovery path.
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }
                .buttonStyle(.link)

                Button("Later") { onDone() }
                    .buttonStyle(.link)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}
