import AppKit
import os
import PewterCore

/// Maps an attributed string (AppKit's RTF importer output) onto Core's
/// `RichTextBlock` model, so `MarkdownWriter` — and its tests — own every
/// emission rule. This adapter only extracts structure the attributes
/// actually assert: font traits, links, text lists, monospaced runs.
/// Anything else stays plain — including indentation, which in RTF is
/// layout far more often than quotation.
@MainActor
enum AttributedTextBlocks {
    private static let logger = Logger(subsystem: "com.oakoss.Pewter", category: "capture")

    static func blocks(fromRTF data: Data) -> [RichTextBlock]? {
        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return blocks(from: attributed)
        } catch {
            logger.info("rtf import failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func blocks(from attributed: NSAttributedString) -> [RichTextBlock] {
        let string = attributed.string as NSString
        guard string.length > 0 else { return [] }

        var blocks: [RichTextBlock] = []
        var codeLines: [String] = []
        // Blank lines between monospaced paragraphs stay interior to one
        // fence; whether they belong is decided by the paragraph after them.
        var pendingCodeBlanks = 0
        var listCounters: [ObjectIdentifier: Int] = [:]

        func flushCode() {
            pendingCodeBlanks = 0
            guard !codeLines.isEmpty else { return }
            blocks.append(.codeBlock(codeLines))
            codeLines = []
        }

        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: .byParagraphs
        ) { _, paragraphRange, _, _ in
            guard paragraphRange.length > 0 else {
                if !codeLines.isEmpty {
                    pendingCodeBlanks += 1
                }
                return
            }
            let style = attributed.attribute(
                .paragraphStyle, at: paragraphRange.location, effectiveRange: nil
            ) as? NSParagraphStyle

            if isMonospacedParagraph(attributed, paragraphRange), style?.textLists.isEmpty ?? true {
                codeLines.append(contentsOf: Array(repeating: "", count: pendingCodeBlanks))
                pendingCodeBlanks = 0
                codeLines.append(string.substring(with: paragraphRange))
                return
            }
            flushCode()

            if let lists = style?.textLists, let list = lists.last {
                let contentRange = rangeAfterListMarker(in: paragraphRange, string: string)
                let kind: ListKind
                if isOrderedMarker(list.markerFormat) {
                    let key = ObjectIdentifier(list)
                    let number = (listCounters[key] ?? max(1, list.startingItemNumber) - 1) + 1
                    listCounters[key] = number
                    kind = .ordered(number: number)
                } else {
                    kind = .unordered
                }
                blocks.append(.listItem(
                    indent: max(0, lists.count - 1),
                    kind: kind,
                    runs: runs(in: contentRange, of: attributed)
                ))
                return
            }

            let font = attributed.attribute(
                .font, at: paragraphRange.location, effectiveRange: nil
            ) as? NSFont
            if let level = headingLevel(for: font) {
                blocks.append(.heading(level: level, runs: runs(in: paragraphRange, of: attributed)))
                return
            }

            blocks.append(.paragraph(runs(in: paragraphRange, of: attributed)))
        }
        flushCode()
        return blocks
    }

    // MARK: - Runs

    private static func runs(in range: NSRange, of attributed: NSAttributedString) -> [RichTextRun] {
        var runs: [RichTextRun] = []
        attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            let text = (attributed.string as NSString).substring(with: runRange)
            guard !text.isEmpty else { return }

            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let struck = ((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0

            runs.append(RichTextRun(
                text,
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                code: isMonospaced(font),
                strikethrough: struck,
                link: link
            ))
        }
        return runs
    }

    // MARK: - Paragraph shape helpers

    /// The importer bakes the visible list marker into the text itself as
    /// "\t<marker>\t<content>"; skip past it so it isn't duplicated
    /// alongside the Markdown marker the writer emits. The first tab must
    /// sit at the very start — that's the importer's shape, and scanning
    /// further would risk reading a content tab as a marker delimiter. The
    /// window is wide enough for multi-digit, roman, and named markers.
    /// All offsets stay in UTF-16 units — mixing in Character distances
    /// would misalign the range for non-BMP markers.
    private static func rangeAfterListMarker(in paragraphRange: NSRange, string: NSString) -> NSRange {
        guard paragraphRange.length > 1,
              string.character(at: paragraphRange.location) == 0x09
        else { return paragraphRange }
        let searchRange = NSRange(
            location: paragraphRange.location + 1,
            length: min(paragraphRange.length - 1, 31)
        )
        let secondTab = string.range(of: "\t", options: [], range: searchRange)
        guard secondTab.location != NSNotFound else { return paragraphRange }
        let contentStart = secondTab.location + 1
        return NSRange(
            location: contentStart,
            length: paragraphRange.location + paragraphRange.length - contentStart
        )
    }

    private static func isOrderedMarker(_ format: NSTextList.MarkerFormat) -> Bool {
        switch format {
        case .disc, .circle, .hyphen, .box, .check, .diamond, .square:
            false
        default:
            true
        }
    }

    /// The whole paragraph must be monospaced (whitespace-only runs aside)
    /// to read as a code line — a sentence that merely *starts* with a code
    /// fragment keeps its inline-code distinction instead.
    private static func isMonospacedParagraph(_ attributed: NSAttributedString, _ range: NSRange) -> Bool {
        var sawMono = false
        var allMono = true
        attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, stop in
            let text = (attributed.string as NSString).substring(with: runRange)
            guard !text.allSatisfy(\.isWhitespace) else { return }
            if isMonospaced(attributes[.font] as? NSFont) {
                sawMono = true
            } else {
                allMono = false
                stop.pointee = true
            }
        }
        return sawMono && allMono
    }

    private static func isMonospaced(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return true
        }
        return RichTextFont.isMonospacedFamily(font.familyName ?? font.fontName)
    }

    private static func headingLevel(for font: NSFont?) -> Int? {
        guard let font else { return nil }
        return RichTextFont.headingLevel(
            pointSize: font.pointSize,
            isBold: NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        )
    }
}
