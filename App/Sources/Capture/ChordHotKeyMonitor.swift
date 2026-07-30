import AppKit
import Carbon.HIToolbox
import os

/// Registers a system-wide chord hotkey via Carbon's RegisterEventHotKey,
/// which needs no Accessibility or Input Monitoring permission and keeps
/// working when modifier-tap remappers (Karabiner SpaceCadet) break the
/// double-tap gesture.
@MainActor
final class ChordHotKeyMonitor {
    private static let logger = Logger(subsystem: "com.oakoss.SmartList", category: "capture")

    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// The Carbon handler holds an unretained self pointer on a
    /// process-lifetime target; it must not outlive this object.
    isolated deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Returns false when the OS refuses the registration (typically the
    /// chord is already claimed by another app) — surface that, or the
    /// configured trigger silently does nothing.
    @discardableResult
    func start(keyCode: UInt32, modifiers: UInt32) -> Bool {
        stop()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let monitor = Unmanaged<ChordHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers on the main thread for application targets.
                MainActor.assumeIsolated {
                    monitor.onHotKey?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        // Registering without a handler would claim the chord process-wide
        // while doing nothing; bail before that can happen.
        guard installStatus == noErr else {
            Self.logger.error("hotkey handler install failed (\(installStatus))")
            stop()
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x534C_4B31), id: 1) // "SLK1"
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            Self.logger.error("hotkey registration failed (\(registerStatus)) — chord likely taken by another app")
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
    }
}
