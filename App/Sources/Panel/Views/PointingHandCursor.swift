import AppKit
import SwiftUI

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}

/// `set`, not push/pop: the panel can hide mid-hover (hotkey dismiss),
/// where neither an exit hover nor `onDisappear` fires — a pushed cursor
/// would strand the pointing hand on the stack until an unrelated hover
/// rebalanced it. `set` leaves nothing behind.
private struct PointingHandCursor: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .onDisappear {
                // The hover-revealed copy button can vanish mid-hover with
                // no exit event.
                if hovering {
                    NSCursor.arrow.set()
                    hovering = false
                }
            }
    }
}
