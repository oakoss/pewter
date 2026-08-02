import AppKit
import ApplicationServices
import OSLog
import PewterCore

/// Reads the app's own recent unified-logging entries and puts a formatted
/// report on the clipboard, so a "capture did nothing" issue report can
/// carry the decision trail without Console.app or log-CLI knowledge.
enum Diagnostics {
    enum Outcome {
        case copied
        /// The store read failed, but its error text is on the clipboard —
        /// the failure log lands in the very store that failed to read, so
        /// the clipboard is the one channel guaranteed to reach a report.
        case errorCopied
        case failed
    }

    @MainActor
    static func copyReport(now: Date = Date()) async -> Outcome {
        let entries: [DiagnosticsEntry]
        do {
            // Off the main actor: opening and scanning the store costs over
            // a second regardless of entry count (measured ~1.3 s), which
            // would freeze the UI and stall the clipboard tracker's poll.
            entries = try await Task.detached { try recentEntries(now: now) }.value
        } catch {
            Logger.panel.error("diagnostics export failed: \(String(describing: error), privacy: .public)")
            let wrote = Pasteboard.write(DiagnosticsReport.failure(
                header: headerLine(),
                reason: String(describing: error),
                generatedAt: now
            ))
            return wrote ? .errorCopied : .failed
        }
        let report = DiagnosticsReport.render(
            entries: entries,
            header: headerLine(),
            generatedAt: now
        )
        return Pasteboard.write(report) ? .copied : .failed
    }

    /// Version plus the active settings — a "capture did nothing" report
    /// should answer "are you using the trigger you think you are" and
    /// "is Accessibility actually granted" without a follow-up question.
    private static func headerLine() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let capture = HotKeySlot.capture.chord()?.display ?? "off"
        let panel = HotKeySlot.panelToggle.chord()?.display ?? "off"
        return """
        Pewter \(version) (\(build)) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Trigger: \(CaptureSettings.tapModifier.title) · Capture hotkey: \(capture) · Panel hotkey: \(panel)
        Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted") · Launch at login: \(LaunchAtLogin
            .isEnabled ? "on" : "off")
        """
    }

    private static func recentEntries(now: Date) throws -> [DiagnosticsEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: now.addingTimeInterval(-DiagnosticsReport.window))
        return try store.getEntries(
            at: position,
            matching: NSPredicate(format: "subsystem == %@", Logger.pewterSubsystem)
        )
        .compactMap { $0 as? OSLogEntryLog }
        .map { entry in
            DiagnosticsEntry(
                date: entry.date,
                category: entry.category,
                level: label(for: entry.level),
                message: entry.composedMessage
            )
        }
    }

    private static func label(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "?"
        @unknown default: "?"
        }
    }
}
