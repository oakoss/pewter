import Foundation
import os

/// The capturable flavors of one pasteboard read. Each flavor is fetched
/// lazily, on first access, since pasteboard flavors can be promised and
/// materialized by the source app on demand — reading a flavor the cascade
/// never reaches would otherwise pay provider IPC for bytes that get
/// discarded.
@MainActor
public struct PasteboardFlavors {
    private let htmlProvider: () -> Data?
    private let rtfProvider: () -> Data?
    private let plainProvider: () -> String?

    /// Every access re-invokes the provider — read a flavor once.
    public var html: Data? {
        htmlProvider()
    }

    public var rtf: Data? {
        rtfProvider()
    }

    public var plain: String? {
        plainProvider()
    }

    public init(
        html: @escaping @autoclosure () -> Data? = nil,
        rtf: @escaping @autoclosure () -> Data? = nil,
        plain: @escaping @autoclosure () -> String? = nil
    ) {
        htmlProvider = html
        rtfProvider = rtf
        plainProvider = plain
    }
}

/// Chooses the text a capture stores, best flavor first: HTML, then RTF,
/// converted to Markdown so captured formatting survives in a file that
/// already speaks Markdown. An unstyled conversion steps aside for the
/// plain flavor, which keeps the source's exact whitespace the rich walks
/// collapse; every abandoned flavor logs why, so a "formatting
/// disappeared" report has a trail.
@MainActor
enum RichCapture {
    private static let logger = Logger(subsystem: "com.oakoss.Pewter", category: "capture")

    /// Flavors above this size skip conversion — a payload this large means
    /// a full-page copy, and the parse cost would land on the main actor
    /// mid-gesture. Checked once per flavor, on the raw bytes as they came
    /// off the pasteboard, before any decode.
    static let byteCeiling = 1_000_000

    /// `rtfBlocks` decodes RTF data into blocks — AppKit's importer in the
    /// app, a fake in tests — so the cascade itself runs under `swift test`.
    static func text(
        from flavors: PasteboardFlavors,
        rtfBlocks: (Data) -> [RichTextBlock]?
    ) -> String? {
        var unstyled: String?

        if let data = flavors.html {
            if data.count > byteCeiling {
                logger.info("skipping html flavor: \(data.count) bytes over the conversion ceiling")
            } else if let html = HTMLMarkdown.decode(data) {
                if let conversion = HTMLMarkdown.convert(fromHTML: html) {
                    if conversion.styled {
                        return conversion.markdown
                    }
                    // "Needed no markdown" logs demote the flavor to a
                    // rescue rather than skip it outright — it can still be
                    // the capture when no plain flavor exists.
                    unstyled = conversion.markdown
                    logger.info("html flavor needed no markdown")
                } else {
                    logger.info("skipping html flavor: \(data.count) bytes yielded no markdown")
                }
            } else {
                logger.info("skipping html flavor: \(data.count) bytes decoded as neither utf8 nor utf16")
            }
        }

        if let data = flavors.rtf {
            if data.count > byteCeiling {
                logger.info("skipping rtf flavor: \(data.count) bytes over the conversion ceiling")
            } else if let blocks = rtfBlocks(data) {
                let markdown = MarkdownWriter.markdown(from: blocks)
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("skipping rtf flavor: converted to empty markdown")
                } else if blocks.requiresMarkdown {
                    return markdown
                } else {
                    // The earlier flavor's rescue wins, matching the
                    // cascade order.
                    unstyled = unstyled ?? markdown
                    logger.info("rtf flavor needed no markdown")
                }
            } else {
                logger.info("skipping rtf flavor: \(data.count) bytes did not import")
            }
        }

        // The unstyled conversion is only a rescue for rich-only
        // pasteboards; a present plain flavor always wins on fidelity.
        return flavors.plain ?? unstyled
    }
}
