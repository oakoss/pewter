import CoreGraphics

/// Screen-space primitives shared by the placement policies (AppKit
/// bottom-left coordinates throughout). Policies — where a panel or HUD
/// wants to be — stay in their own types; this owns the mechanics every
/// policy needs.
public enum ScreenGeometry {
    /// The corner that stays visible when a rect doesn't fit its bounds.
    /// Naming it is the point: the winning corner is domain knowledge
    /// (where the content's controls or anchor live), not an
    /// argument-order puzzle in nested max(min(...)) calls.
    public enum Corner {
        /// Feedback hanging from an anchor: the anchored edge stays put.
        case bottomLeft
        /// Window chrome: the controls at the top-left stay reachable.
        case topLeft
    }

    /// Clamps `rect` inside `bounds` with `inset` margins on every side.
    /// An oversized rect keeps the named corner visible and overflows on
    /// the opposite edges.
    public static func clamp(
        _ rect: CGRect,
        inside bounds: CGRect,
        inset: CGFloat,
        keeping corner: Corner
    ) -> CGRect {
        var origin = rect.origin
        origin.x = max(min(origin.x, bounds.maxX - rect.width - inset), bounds.minX + inset)
        switch corner {
        case .bottomLeft:
            origin.y = max(min(origin.y, bounds.maxY - rect.height - inset), bounds.minY + inset)
        case .topLeft:
            origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - rect.height - inset)
        }
        return CGRect(origin: origin, size: rect.size)
    }

    /// Index into `screens` of the frame that should host content anchored
    /// at `anchor`: greatest overlap area first. A zero-area anchor (a
    /// mouse point, a caret) matches by edge-inclusive containment — a
    /// cursor pinned to a screen's top or right edge reports exactly
    /// maxY/maxX, which exclusive-edge intersection misses. nil when no
    /// screen matches.
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
}
