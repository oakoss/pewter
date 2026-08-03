import AppKit

/// Answers "would a line clamp hide any of this text at this width" on a
/// detached TextKit stack. Measuring the live view's layout instead turned
/// out to strand stale verdicts: sizeThatFits probes mutate the shared
/// container, and a report computed at a provisional width could survive
/// with no later pass to correct it.
enum TextTruncation {
    @MainActor
    static func clampHidesText(
        _ attributed: NSAttributedString,
        width: CGFloat,
        lineLimit: Int
    ) -> Bool {
        guard width > 0, attributed.length > 0 else { return false }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        // One line past the limit is all the answer needs; without the cap,
        // a capture-length note pays full layout on every measurement.
        container.maximumNumberOfLines = lineLimit + 1
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        var lines = 0
        let laidOut = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: laidOut) { _, _, _, _, _ in
            lines += 1
        }
        return lines > lineLimit
    }
}
