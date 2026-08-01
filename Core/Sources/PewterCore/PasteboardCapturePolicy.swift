/// Pure decision tables for the pasteboard capture tier; the sequencing
/// that feeds them lives in `PasteboardCaptureRunner`.
public enum PasteboardCapturePolicy {
    /// What a pasteboard read yields as a capture. Whitespace-only text
    /// survives here — normalization is the store's job — but no string at
    /// all (image or file selection) is not a capture.
    public static func capturedResult(from text: String?) -> PasteboardCaptureResult {
        guard let text, !text.isEmpty else { return .nothingSelected }
        return .copied(text)
    }

    public enum RestoreDecision: Equatable, Sendable {
        case restore
        /// Nothing restorable was saved; clearing would erase the captured
        /// text without putting anything back.
        case skipEmptySnapshot
        /// Something else wrote since the synthetic copy (clipboard manager,
        /// the user) — clobbering that write is worse than skipping.
        case skipClipboardMoved
    }

    public static func restoreDecision(
        snapshotIsEmpty: Bool,
        changeCount: Int,
        expectedChangeCount: Int
    ) -> RestoreDecision {
        if snapshotIsEmpty {
            return .skipEmptySnapshot
        }
        if changeCount != expectedChangeCount {
            return .skipClipboardMoved
        }
        return .restore
    }
}
