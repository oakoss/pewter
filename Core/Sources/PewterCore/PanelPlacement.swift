import CoreGraphics

/// Screen-to-screen frame translation for hotkey summons: the panel follows
/// the user to the active screen, keeping the position they gave it.
public enum PanelPlacement {
    /// Translates `frame` from `source` onto `target` (both visible areas,
    /// AppKit bottom-left coordinates), preserving the frame's top-left
    /// offset within its screen — top-left because the panel hangs from the
    /// menu bar area, so distance-from-top is what reads as "the same spot"
    /// across screens of different heights. The result is clamped inside
    /// `target` with `inset` margins; a frame larger than the target still
    /// keeps its top-left corner visible.
    public static func translate(
        frame: CGRect,
        from source: CGRect,
        to target: CGRect,
        inset: CGFloat = 8
    ) -> CGRect {
        let offsetX = frame.minX - source.minX
        let topOffset = source.maxY - frame.maxY

        let origin = CGPoint(
            x: target.minX + offsetX,
            y: target.maxY - topOffset - frame.height
        )
        return ScreenGeometry.clamp(
            CGRect(origin: origin, size: frame.size),
            inside: target,
            inset: inset,
            keeping: .topLeft
        )
    }
}
