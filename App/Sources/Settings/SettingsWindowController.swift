import AppKit
import os
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
    /// 670pt clears every common state — idle 592.5, any single hint,
    /// approval plus one recorder hint at 664.5 (measured). The tallest
    /// reachable state (both recorder hints plus the approval hint, 700.5)
    /// scrolls rather than costing 140pt of idle dead space; hints sit in
    /// the top sections, so they stay visible regardless.
    private static let contentSize = NSSize(width: 520, height: 670)

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
        // different one; the window is not user-resizable. Clamped so
        // scaled display modes (1024×640 with larger text) never push the
        // bottom off screen — the form scrolls when clamped.
        let usable = (window.screen ?? NSScreen.main)?.visibleFrame.height
        let maxContent = usable.map {
            window.contentRect(
                forFrameRect: NSRect(origin: .zero, size: NSSize(width: Self.contentSize.width, height: $0))
            ).height
        } ?? Self.contentSize.height
        window.setContentSize(NSSize(
            width: Self.contentSize.width,
            height: min(Self.contentSize.height, maxContent)
        ))
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
            Section("General") {
                LaunchAtLoginRow()
            }

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

private struct LaunchAtLoginRow: View {
    /// One value carries both the text and whether the Open button shows,
    /// so they can't drift apart the way a snapshotted string next to a
    /// live status read would.
    private enum Hint: Equatable {
        case failed(String)
        case needsApproval

        var text: String {
            switch self {
            case let .failed(message): message
            case .needsApproval: "Approve Pewter under Login Items to finish"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.oakoss.Pewter", category: "settings")

    @State private var isOn = LaunchAtLogin.isEnabled
    @State private var hint: Hint?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text("Launch at login")
                Text("Open Pewter automatically when you log in")
            }
            .onChange(of: isOn) {
                apply()
            }
            if let hint {
                HStack(spacing: 8) {
                    Text(hint.text)
                        .font(.caption)
                        // Approval is an instruction, not a failure.
                        .foregroundStyle(hint == .needsApproval ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    if hint == .needsApproval {
                        Button("Open Login Items…") {
                            LaunchAtLogin.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        // The Open button sends the user to System Settings and back with
        // the window still open; re-sync on return or the toggle keeps
        // showing off after the approval it asked for.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resync()
        }
    }

    private func apply() {
        let wanted = isOn
        // Also breaks the loop when the snap-back below re-fires onChange.
        guard wanted != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(wanted)
        } catch {
            // SMAppServiceErrorDomain ships no localized strings, so the
            // raw error goes to the log, not the settings window.
            Self.logger
                .error(
                    "Login Items \(wanted ? "register" : "unregister", privacy: .public) failed: \(error, privacy: .public)"
                )
        }
        // The hint derives from the observed outcome, not from whether the
        // call threw: register() can return success into a pending state,
        // and a toggle that snaps back must always say why.
        let status = LaunchAtLogin.status
        isOn = status == .enabled
        if wanted == isOn {
            hint = nil
        } else if wanted, status == .requiresApproval {
            hint = .needsApproval
        } else {
            hint = .failed(wanted ? "Couldn't turn on Launch at login" : "Couldn't turn off Launch at login")
        }
    }

    private func resync() {
        let status = LaunchAtLogin.status
        let enabled = status == .enabled
        // An externally observed flip invalidates any hint — a failure
        // message must not survive the user fixing it in System Settings.
        if enabled != isOn {
            isOn = enabled
            hint = nil
            return
        }
        if hint == .needsApproval, status != .requiresApproval {
            hint = nil
        }
    }
}
