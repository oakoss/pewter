import Foundation

/// One styled run of inline text. The flags mirror what Markdown can
/// express inline; anything richer is dropped by the adapters, never
/// approximated.
public struct RichTextRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    /// When set, `bold` and `italic` are ignored at emission — code
    /// formatting wins over emphasis.
    public var code: Bool
    public var strikethrough: Bool
    public var link: String?

    public init(
        _ text: String,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        strikethrough: Bool = false,
        link: String? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strikethrough = strikethrough
        // An empty href means "no link"; one representation spares every
        // consumer the guard.
        self.link = link.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum ListKind: Equatable, Sendable {
    case unordered
    /// The resolved ordinal — only an ordered item has one, so an ignored
    /// number on a bullet is unrepresentable.
    case ordered(number: Int)
}

/// One block of a rich-text capture, the shared shape between the HTML
/// parser (Core) and the attributed-string adapter (App). `MarkdownWriter`
/// serializes it, so every emission rule is testable without AppKit.
public enum RichTextBlock: Equatable, Sendable {
    case paragraph([RichTextRun])
    /// Levels are clamped into 1...3 at emission — deep heading hierarchies
    /// read as noise in a notes file.
    case heading(level: Int, runs: [RichTextRun])
    /// `indent` is nesting depth, 0 for a top-level item.
    case listItem(indent: Int, kind: ListKind, runs: [RichTextRun])
    /// One element per line, newline-free; fenced on emission with a fence
    /// longer than any backtick run in the lines.
    case codeBlock([String])
    case quote([RichTextRun])
}

/// Font-classification rules shared by the HTML parser (Core) and the
/// attributed-string adapter (App), so both capture paths agree on what
/// reads as code and what reads as a heading.
public enum RichTextFont {
    /// Family names that read as code — checked by containment, so quoted
    /// CSS lists and suffixed PostScript names ("Menlo-Regular") register.
    private static let monospacedFamilies = [
        "menlo", "monaco", "courier", "sf mono", "consolas", "monospace",
    ]

    public static func isMonospacedFamily(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return monospacedFamilies.contains { lowered.contains($0) }
    }

    /// Buckets a bold font's size into a heading level. The smallest bucket
    /// starts at 17pt, above the ~12–16pt body range of most rich text, so
    /// ordinary bold text never reads as a heading.
    public static func headingLevel(pointSize: Double, isBold: Bool) -> Int? {
        guard isBold else { return nil }
        return switch pointSize {
        case 24...: 1
        case 20 ..< 24: 2
        case 17 ..< 20: 3
        default: nil
        }
    }
}

public extension [RichTextBlock] {
    /// True when anything here actually needs Markdown — any structural
    /// block, or any styled run. An unstyled conversion gained nothing over
    /// the plain-text flavor, which kept the source's exact whitespace.
    var requiresMarkdown: Bool {
        contains { block in
            guard case let .paragraph(runs) = block else { return true }
            return runs.contains { $0.bold || $0.italic || $0.code || $0.strikethrough || $0.link != nil }
        }
    }
}
