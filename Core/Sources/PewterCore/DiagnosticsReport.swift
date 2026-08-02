import Foundation

/// One unified-logging entry, decoupled from OSLogStore so report
/// rendering is table-testable.
public struct DiagnosticsEntry: Equatable, Sendable {
    public var date: Date
    public var category: String
    public var level: String
    public var message: String

    public init(date: Date, category: String, level: String, message: String) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Renders recent log entries as the text Copy Diagnostics puts on the
/// clipboard — the capture decision trail, formatted for pasting into an
/// issue report.
public enum DiagnosticsReport {
    /// How far back the collector reads.
    public static let window: TimeInterval = 10 * 60

    public static func render(
        entries: [DiagnosticsEntry],
        header: String,
        generatedAt: Date,
        timeZone: TimeZone = .current,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        var lines = [header, windowLine(generatedAt, timeZone), ""]
        guard !entries.isEmpty else {
            lines.append("No log entries in the window.")
            return finish(lines, homeDirectory: homeDirectory)
        }

        let clock = formatter("HH:mm:ss.SSS", timeZone)
        // Index tie-break: Swift's sort is not guaranteed stable, and
        // same-millisecond entries reordering would scramble the decision
        // trail exactly where ordering matters.
        let ordered = entries.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        for entry in ordered {
            let prefix = "\(clock.string(from: entry.date)) \(pad(entry.level, to: 6)) \(pad(entry.category, to: 8)) "
            var pieces = entry.message.split(separator: "\n", omittingEmptySubsequences: false)
            // A message's trailing newline would render as an indent-only
            // line of trailing whitespace.
            while pieces.count > 1, pieces.last?.isEmpty == true {
                pieces.removeLast()
            }
            lines.append(prefix + (pieces.first.map(String.init) ?? ""))
            // Continuation lines align under the message column so a
            // multi-line entry reads as one entry, not several.
            let indent = String(repeating: " ", count: prefix.count)
            for continuation in pieces.dropFirst() {
                lines.append(indent + continuation)
            }
        }
        return finish(lines, homeDirectory: homeDirectory)
    }

    /// The store-read-failed report. Lives here, not in the collector, so
    /// the path most likely to reach an issue report is under the same
    /// tests as the one that worked.
    public static func failure(
        header: String,
        reason: String,
        generatedAt: Date,
        timeZone: TimeZone = .current,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        finish(
            [header, windowLine(generatedAt, timeZone), "", "Diagnostics export failed: \(reason)"],
            homeDirectory: homeDirectory
        )
    }

    private static func windowLine(_ generatedAt: Date, _ timeZone: TimeZone) -> String {
        let minutes = Int(window) / 60
        let unit = minutes == 1 ? "minute" : "minutes"
        let stamp = formatter("yyyy-MM-dd HH:mm:ss Z", timeZone)
        return "Log window: last \(minutes) \(unit), generated \(stamp.string(from: generatedAt))"
    }

    /// The home path names the user; a pasted report shouldn't. Scrubbing
    /// at this chokepoint covers every log site — annotating individual
    /// interpolations is a convention nothing enforces.
    private static func finish(_ lines: [String], homeDirectory: String) -> String {
        let joined = lines.joined(separator: "\n")
        guard homeDirectory.count > 1 else { return joined }
        return joined.replacingOccurrences(of: homeDirectory, with: "~")
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
