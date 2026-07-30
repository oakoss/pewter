import AppKit
import os
import SmartListCore

/// Feeds NSEvents into the `ModifierTapDetector` state machine for the
/// configured double-tap modifier.
///
/// Uses NSEvent monitors, which need only the Accessibility grant (a
/// CGEventTap would add a separate Input Monitoring prompt). Global monitors
/// never see events targeted at our own app, so a local monitor mirrors into
/// the same state machine. The global monitor registered before Accessibility
/// is granted silently never fires — call `start()` again after the grant.
@MainActor
final class ModifierTapMonitor {
    private static let logger = Logger(subsystem: "com.oakoss.SmartList", category: "capture")

    var onDoubleTap: (() -> Void)?

    private var detector = ModifierTapDetector()
    private var target: NSEvent.ModifierFlags = .shift
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(target: NSEvent.ModifierFlags) {
        stop()
        self.target = target
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // AppKit delivers monitor events on the installing (main) thread;
            // not a documented contract, so fail loudly if it ever changes.
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
        if globalMonitor == nil || localMonitor == nil {
            Self.logger.error("event monitor registration returned nil; double-tap trigger degraded")
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        detector = ModifierTapDetector()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            detector.handleGestureBreak()

        case .flagsChanged:
            // Deliberately excludes .capsLock and .function: a latched Caps
            // Lock or a held fn/globe key must not break the gesture.
            let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])

            let modifierEvent: ModifierTapDetector.ModifierEvent = if flags == target {
                .targetAlone
            } else if flags.isEmpty {
                .none
            } else {
                .other(targetHeld: !flags.intersection(target).isEmpty)
            }

            if detector.handleModifiers(modifierEvent, timestamp: event.timestamp) {
                onDoubleTap?()
            }

        default:
            break
        }
    }
}
