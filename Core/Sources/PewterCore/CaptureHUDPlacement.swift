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
        origin.x = max(min(origin.x, screen.maxX - size.width - inset), screen.minX + inset)
        origin.y = max(min(origin.y, screen.maxY - size.height - inset), screen.minY + inset)
        return CGRect(origin: origin, size: size)
    }

    /// Index into `screens` of the frame that should host a HUD anchored at
    /// `anchor`: greatest overlap area first. A zero-area anchor (the mouse
    /// point, a caret) matches by edge-inclusive containment — a cursor
    /// pinned to a screen's top or right edge reports exactly maxY/maxX,
    /// which exclusive-edge intersection misses. nil when no screen matches.
    public static func screenIndex(for anchor: CGRect, in screens: [CGRect]) -> Int? {
        let overlaps = screens.map { screen in
            let intersection = screen.intersection(anchor)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
            return best
        }
        return screens.firstIndex { screen in
            (screen.minX ... screen.maxX).contains(anchor.midX)
                && (screen.minY ... screen.maxY).contains(anchor.midY)
        }
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
        guard screenIndex(for: converted, in: screens) != nil else { return nil }
        return converted
    }
}
