import AppKit
import PewterCore
import SwiftUI

/// Callbacks into AppDelegate, the single writer of hotkey settings. The
/// apply closures persist the chord, arm it, restore the previous chord on
/// refusal, and return a user-facing error when the OS refuses.
@MainActor
struct SettingsActions {
    var applyCaptureChord: (KeyChord?) -> String?
    var applyToggleChord: (KeyChord?) -> String?
    var applyTapModifier: () -> Void
    /// Disarm/re-arm all capture triggers around recording — pressing the
    /// currently assigned chord must record, not fire. Resume reports
    /// per-target arming success so refusals render as recorder hints.
    var suspendHotKeys: () -> Void
    var resumeHotKeys: () -> (captureOK: Bool, toggleOK: Bool)
}

/// A normal activating titled window, on the onboarding pattern. The
/// SwiftUI Settings scene is deliberately not used: for LSUIElement apps
/// it needs activation-policy flipping hacks and is broken on macOS 26.
@MainActor
final class SettingsWindowController {
    /// 570pt fits the tallest reachable state — both recorders showing
    /// their longest hint (measured 568.5) — so the form never scrolls.
    private static let contentSize = NSSize(width: 520, height: 570)

    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private let actions: SettingsActions
    private let recorder: KeyRecorderModel

    init(actions: SettingsActions) {
        self.actions = actions
        recorder = KeyRecorderModel(actions: actions)
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func show() {
        let window = window ?? makeWindow()
        // Rebuilt on every show: view state initializers read the stored
        // settings, which launch-time arming can revert behind a kept view.
        recorder.refresh()
        let hosting = NSHostingView(rootView: SettingsView(recorder: recorder, actions: actions))
        // Fixed-size window, scrolling grouped Form — same pattern as
        // PanelController. Content-driven window sizing (preferredContentSize
        // observed) feeds the Form's scroll-view layout back into the window
        // and AppKit aborts with an update-constraints loop.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pewter Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PewterSettings")
        if !window.setFrameUsingName("PewterSettings") {
            window.center()
        }
        // Normalize the height even when a stale autosaved frame restores a
        // different one; the window is not user-resizable.
        window.setContentSize(Self.contentSize)
        // Closing or losing key mid-recording must cancel it: the window is
        // reused (orderOut, not teardown) so onDisappear never fires, and
        // the local monitor is app-wide — left alive it would swallow every
        // keystroke, including the panel's.
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak recorder] _ in
                MainActor.assumeIsolated {
                    recorder?.cancel()
                }
            })
        }
        self.window = window
        return window
    }
}

private struct SettingsView: View {
    let recorder: KeyRecorderModel
    let actions: SettingsActions

    @State private var tapModifier = CaptureSettings.tapModifier
    @State private var listStyle = PanelSettings.listCopyStyle

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent {
                    KeyRecorderView(target: .capture, model: recorder)
                } label: {
                    Text("Capture selection")
                    Text("Works even where the double-tap can't — no Accessibility needed")
                }

                LabeledContent {
                    KeyRecorderView(target: .panelToggle, model: recorder)
                } label: {
                    Text("Show or hide panel")
                    Text("Summons the panel from any app")
                }

                Picker(selection: $tapModifier) {
                    ForEach(CaptureSettings.TapModifier.allCases, id: \.self) {
                        Text($0.menuTitle).tag($0)
                    }
                } label: {
                    Text("Capture gesture")
                    Text("Double-tap this modifier to capture the selection")
                }
                .onChange(of: tapModifier) {
                    CaptureSettings.tapModifier = tapModifier
                    actions.applyTapModifier()
                }
            }

            Section("Copying") {
                Picker("Copy as List style", selection: $listStyle) {
                    ForEach(ItemFormatter.ListStyle.allCases, id: \.self) {
                        Text($0.menuTitle).tag($0)
                    }
                }
                .onChange(of: listStyle) {
                    PanelSettings.listCopyStyle = listStyle
                }
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Link("Pewter on GitHub", destination: URL(string: "https://github.com/oakoss/pewter")!)
            } header: {
                Text("About")
            } footer: {
                Text("Your notes are a plain markdown file. Nothing leaves your Mac.")
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
