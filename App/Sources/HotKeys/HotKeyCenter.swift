import AppKit
import Carbon.HIToolbox
import os
import PewterCore

/// Owns every Carbon hotkey registration behind one process-wide event
/// handler. RegisterEventHotKey needs no Accessibility or Input Monitoring
/// permission and keeps working when modifier-tap remappers (Karabiner
/// SpaceCadet) break the double-tap gesture.
@MainActor
final class HotKeyCenter {
    struct Chord: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    enum ArmResult {
        case unchanged, applied, failed
    }

    private static let logger = Logger.hotkey
    private static let signature = OSType(0x534C_4B31) // "SLK1"

    private var handlers: [UInt32: () -> Void] = [:]
    private var registrations: [UInt32: (chord: Chord, ref: EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?

    /// The Carbon handler holds an unretained self pointer on a
    /// process-lifetime target; it must not outlive this object.
    isolated deinit {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func setHandler(for slot: HotKeySlot, _ handler: @escaping () -> Void) {
        handlers[slot.rawValue] = handler
    }

    /// Brings the registration for `id` to `chord` (nil disarms). Reports
    /// `.unchanged` without touching the OS — a needless re-registration
    /// that transiently failed would flip the user's hotkey off. `.failed`
    /// means the OS refused the chord (typically claimed by another app);
    /// surface that, or the configured trigger silently does nothing.
    func arm(_ slot: HotKeySlot, chord: Chord?) -> ArmResult {
        let current = registrations[slot.rawValue]
        guard chord != current?.chord else { return .unchanged }

        if let current {
            UnregisterEventHotKey(current.ref)
            registrations[slot.rawValue] = nil
        }
        guard let chord else { return .applied }

        guard installHandlerIfNeeded() else { return .failed }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            EventHotKeyID(signature: Self.signature, id: slot.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Self.logger.error("hotkey registration failed (\(status)) — chord likely taken by another app")
            return .failed
        }
        registrations[slot.rawValue] = (chord, ref)
        return .applied
    }

    /// Registering without a handler would claim a chord process-wide while
    /// doing nothing; the handler is installed lazily before the first
    /// registration and stays for the process's lifetime.
    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                var pressedID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard paramStatus == noErr else {
                    // The press dies here with nothing else to catch it —
                    // log it or the dead hotkey is undiagnosable.
                    MainActor.assumeIsolated {
                        HotKeyCenter.logger.error("hotkey id read failed (\(paramStatus))")
                    }
                    return OSStatus(eventNotHandledErr)
                }
                guard pressedID.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers on the main thread for application targets.
                return MainActor.assumeIsolated {
                    guard let handler = center.handlers[pressedID.id] else {
                        return OSStatus(eventNotHandledErr)
                    }
                    handler()
                    return noErr
                }
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        guard status == noErr else {
            Self.logger.error("hotkey handler install failed (\(status))")
            eventHandler = nil
            return false
        }
        return true
    }
}
