import Foundation
@testable import PewterCore
import Testing

@MainActor
struct RichCaptureTests {
    private func text(
        html: String? = nil,
        htmlData: Data? = nil,
        rtf: Data? = nil,
        plain: String? = nil,
        rtfBlocks: (Data) -> [RichTextBlock]? = { _ in nil }
    ) -> String? {
        RichCapture.text(
            from: PasteboardFlavors(
                html: htmlData ?? html.map { Data($0.utf8) },
                rtf: rtf,
                plain: plain
            ),
            rtfBlocks: rtfBlocks
        )
    }

    @Test func styledHtmlBeatsThePlainFlavor() {
        #expect(text(html: "<b>bold</b>", plain: "bold") == "**bold**")
    }

    @Test func styledHtmlBeatsTheRtfFlavor() {
        let result = text(html: "<b>bold</b>", rtf: Data([0x01]), rtfBlocks: { _ in
            [.heading(level: 1, runs: [RichTextRun("Title")])]
        })
        #expect(result == "**bold**")
    }

    @Test func winningHtmlLeavesLowerFlavorsUnread() {
        var rtfRead = false
        var plainRead = false
        let flavors = PasteboardFlavors(
            html: Data("<b>bold</b>".utf8),
            rtf: { () -> Data? in rtfRead = true
                return nil
            }(),
            plain: { () -> String? in plainRead = true
                return nil
            }()
        )
        #expect(RichCapture.text(from: flavors, rtfBlocks: { _ in nil }) == "**bold**")
        #expect(!rtfRead)
        #expect(!plainRead)
    }

    @Test func eachFlavorProviderIsReadAtMostOnce() {
        var htmlReads = 0
        var rtfReads = 0
        var plainReads = 0
        let flavors = PasteboardFlavors(
            html: { () -> Data? in htmlReads += 1
                return Data("<p>plain para</p>".utf8)
            }(),
            rtf: { () -> Data? in rtfReads += 1
                return Data([0x01])
            }(),
            plain: { () -> String? in plainReads += 1
                return nil
            }()
        )
        #expect(RichCapture.text(from: flavors, rtfBlocks: { _ in nil }) == "plain para")
        #expect(htmlReads == 1)
        #expect(rtfReads == 1)
        #expect(plainReads == 1)
    }

    @Test func markupOnlyHtmlFallsThroughToRtf() {
        let result = text(html: "<style>p { color: red }</style>", rtf: Data([0x01]), rtfBlocks: { _ in
            [.heading(level: 1, runs: [RichTextRun("Title")])]
        })
        #expect(result == "# Title")
    }

    @Test func unstyledHtmlDefersToThePlainFlavor() {
        #expect(text(html: "<p>two  spaces</p>", plain: "two  spaces") == "two  spaces")
    }

    @Test func unstyledHtmlRescuesARichOnlyPasteboard() {
        #expect(text(html: "<p>only flavor</p>") == "only flavor")
    }

    @Test func oversizedHtmlFallsThroughToPlain() {
        let huge = Data(repeating: UInt8(ascii: "a"), count: RichCapture.byteCeiling + 1)
        #expect(text(htmlData: huge, plain: "plain") == "plain")
    }

    @Test func undecodableHtmlFallsThroughToRtf() {
        // Invalid UTF-8 and invalid UTF-16 (odd length): decode fails.
        let garbage = Data([0xC3])
        let result = text(htmlData: garbage, rtf: Data([0x01]), rtfBlocks: { _ in
            [.heading(level: 1, runs: [RichTextRun("Title")])]
        })
        #expect(result == "# Title")
    }

    @Test func rtfBlocksNeedingMarkdownWin() {
        let result = text(rtf: Data([0x01]), plain: "Title", rtfBlocks: { _ in
            [.heading(level: 1, runs: [RichTextRun("Title")])]
        })
        #expect(result == "# Title")
    }

    @Test func oversizedRtfIsNeverDecoded() {
        var decoded = false
        let huge = Data(count: RichCapture.byteCeiling + 1)
        let result = text(rtf: huge, plain: "plain", rtfBlocks: { _ in
            decoded = true
            return [.heading(level: 1, runs: [RichTextRun("Title")])]
        })
        #expect(result == "plain")
        #expect(!decoded)
    }

    @Test func plainRtfBlocksDeferToThePlainFlavor() {
        let result = text(rtf: Data([0x01]), plain: "exact  whitespace", rtfBlocks: { _ in
            [.paragraph([RichTextRun("exact whitespace")])]
        })
        #expect(result == "exact  whitespace")
    }

    @Test func plainRtfBlocksRescueARichOnlyPasteboard() {
        let result = text(rtf: Data([0x01]), rtfBlocks: { _ in
            [.paragraph([RichTextRun("only flavor")])]
        })
        #expect(result == "only flavor")
    }

    @Test func rtfConvertingToEmptyMarkdownFallsThroughToPlain() {
        let result = text(rtf: Data([0x01]), plain: "plain", rtfBlocks: { _ in
            [.paragraph([RichTextRun(" ", bold: true)])]
        })
        #expect(result == "plain")
    }

    @Test func failedRtfImportFallsThroughToPlain() {
        #expect(text(rtf: Data([0x01]), plain: "plain") == "plain")
    }

    @Test func plainOnlyPasteboardCapturesPlain() {
        #expect(text(plain: "just text") == "just text")
    }

    @Test func emptyPasteboardCapturesNothing() {
        #expect(text() == nil)
    }
}
