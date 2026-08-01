import PewterCore
import Testing

struct RichTextFontTests {
    @Test func monospacedFamiliesMatchByContainment() {
        #expect(RichTextFont.isMonospacedFamily("Menlo"))
        #expect(RichTextFont.isMonospacedFamily("Menlo-Regular"))
        #expect(RichTextFont.isMonospacedFamily("SF Mono"))
        #expect(RichTextFont.isMonospacedFamily("'Courier New', monospace"))
        #expect(RichTextFont.isMonospacedFamily("monospace"))
        #expect(!RichTextFont.isMonospacedFamily("Helvetica"))
        #expect(!RichTextFont.isMonospacedFamily("Times New Roman"))
    }

    @Test func headingLevelsBucketBoldSizes() {
        #expect(RichTextFont.headingLevel(pointSize: 28, isBold: true) == 1)
        #expect(RichTextFont.headingLevel(pointSize: 24, isBold: true) == 1)
        #expect(RichTextFont.headingLevel(pointSize: 21, isBold: true) == 2)
        #expect(RichTextFont.headingLevel(pointSize: 17, isBold: true) == 3)
        #expect(RichTextFont.headingLevel(pointSize: 16, isBold: true) == nil)
        #expect(RichTextFont.headingLevel(pointSize: 28, isBold: false) == nil)
    }
}
