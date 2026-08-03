import CoreGraphics

/// Places the capture HUD near the point of capture (AppKit bottom-left
/// coordinates throughout). A zero-size anchor is a point — the mouse
/// fallback when the selection's bounds are unavailable.
public enum CaptureHUDPlacement {
    /// Centers the HUD horizontally on the anchor and hangs it below, so the
    /// just-captured line stays unobscured; too close to the bottom edge it
    /// flips above instead. When the size fits, the result is clamped inside
    /// `screen` (a visible frame) with `inset` margins on every side; an
    /// oversized frame keeps its bottom-left edge visible.
    public static func frame(
        anchor: CGRect,
        size: CGSize,
        screen: CGRect,
        gap: CGFloat = 8,
        inset: CGFloat = 8
    ) -> CGRect {
        var origin = CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - gap - size.height
        )
        if origin.y < screen.minY + inset {
            origin.y = anchor.maxY + gap
        }
        return ScreenGeometry.clamp(
            CGRect(origin: origin, size: size),
            inside: screen,
            inset: inset,
            keeping: .bottomLeft
        )
    }

    /// Converts an AX-reported global rect (top-left origin) into an AppKit
    /// bottom-left anchor, or nil when it can't anchor a HUD: zero height is
    /// an app answering without data, and a rect on no screen is a bogus AX
    /// answer that would fling the HUD somewhere useless. Zero width stays
    /// valid — a caret is a real anchor.
    public static func normalizedAnchor(
        axRect: CGRect,
        primaryHeight: CGFloat,
        screens: [CGRect]
    ) -> CGRect? {
        guard axRect.height > 0 else { return nil }
        let converted = CGRect(
            x: axRect.minX,
            y: primaryHeight - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
        guard ScreenGeometry.screenIndex(for: converted, in: screens) != nil else { return nil }
        return converted
    }
}
