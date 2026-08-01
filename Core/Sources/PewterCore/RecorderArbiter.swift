import Foundation

public enum RecorderDecision: Equatable, Sendable {
    case cancel
    case reject(hint: String)
    case assign(KeyChord)
}

/// The recorder's decision table, kept as a pure function so every hint
/// string and rejection rule runs under `swift test` instead of needing a
/// keyboard.
public enum RecorderArbiter {
    public static func decide(
        _ picked: KeyChord,
        for slot: HotKeySlot,
        assignments: [HotKeySlot: KeyChord]
    ) -> RecorderDecision {
        // Bare Escape cancels the recording, mirroring the system recorder;
        // Esc with a chording modifier is a recordable pick.
        if picked.keyCode == KeyChord.escapeKeyCode, picked.modifiers.isEmpty {
            return .cancel
        }
        guard picked.isValidGlobalHotKey else {
            return .reject(hint: "Include ⌃, ⌥, or ⌘ — a bare key would shadow normal typing")
        }
        guard !picked.isSystemReserved else {
            return .reject(hint: "\(picked.display) would shadow a standard shortcut — add another modifier")
        }
        // The two shortcuts registering the same chord would fail with a
        // misleading "taken by another app" — that app being us.
        if let conflict = assignments.first(where: { $0.key != slot && $0.value == picked })?.key {
            return .reject(hint: "Already used by \(conflict.title)")
        }
        return .assign(picked)
    }
}
