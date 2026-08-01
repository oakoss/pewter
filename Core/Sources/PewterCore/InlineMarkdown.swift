import Foundation
import os

/// Parses a note's text as inline Markdown into `RichTextRun`s — the same
/// shape captures produce — so the display path and the capture pipeline
/// can't drift on what styles exist. Block syntax stays literal; a note
/// renders as one block.
@MainActor
public enum InlineMarkdown {
    private static let logger = Logger(subsystem: "com.oakoss.Pewter", category: "panel")

    /// Parsing runs on every render of a failing note; once per distinct
    /// text keeps the trail without flooding the log.
    private static var loggedFailures: Set<Int> = []

    public static func runs(from text: String) -> [RichTextRun] {
        let markdown: AttributedString
        do {
            markdown = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            // Plain text keeps the note readable, but the fallback also
            // drops every link in it — worth a trail.
            if loggedFailures.insert(text.hashValue).inserted {
                logger.error("markdown parse failed; rendering plain: \(error.localizedDescription, privacy: .public)")
            }
            return [RichTextRun(text)]
        }

        var runs: [RichTextRun] = []
        for run in markdown.runs {
            let piece = String(markdown[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            // An unsafe destination renders as plain text — the same
            // policy that drops it at capture time.
            let link = run.link.flatMap { LinkPolicy.allows($0) ? $0.absoluteString : nil }
            runs.append(RichTextRun(
                piece,
                bold: intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                code: intent.contains(.code),
                strikethrough: intent.contains(.strikethrough),
                link: link
            ))
        }
        return runs
    }
}
