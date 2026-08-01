import CoreGraphics
@testable import PewterCore
import Testing

struct PanelPlacementTests {
    // A 1440x870 "laptop" and a 2560x1415 "external", both with menu-bar
    // style insets already applied (these are visible frames).
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 870)
    private let external = CGRect(x: 1440, y: 200, width: 2560, height: 1415)

    @Test func preservesTopLeftOffsetAcrossScreens() {
        // 100pt from the left edge, 50pt down from the top.
        let frame = CGRect(x: 100, y: 870 - 50 - 480, width: 360, height: 480)
        let moved = PanelPlacement.translate(frame: frame, from: laptop, to: external)

        #expect(moved.minX - external.minX == 100)
        #expect(external.maxY - moved.maxY == 50)
        #expect(moved.size == frame.size)
    }

    @Test func roundTripReturnsToOriginalSpot() {
        let frame = CGRect(x: 220, y: 130, width: 360, height: 480)
        let there = PanelPlacement.translate(frame: frame, from: laptop, to: external)
        let back = PanelPlacement.translate(frame: there, from: external, to: laptop)
        #expect(back == frame)
    }

    @Test func clampsWhenTargetIsSmaller() {
        // Deep in the external display's larger area — off the laptop's.
        let frame = CGRect(x: 1440 + 2000, y: 300, width: 360, height: 480)
        let moved = PanelPlacement.translate(frame: frame, from: external, to: laptop)

        #expect(moved.maxX <= laptop.maxX - 8)
        #expect(moved.minY >= laptop.minY + 8)
        #expect(moved.minX >= laptop.minX + 8)
        #expect(moved.maxY <= laptop.maxY - 8)
    }

    @Test func overWideFrameKeepsLeftEdgeVisible() {
        let frame = CGRect(x: 1500, y: 300, width: 1600, height: 480)
        let moved = PanelPlacement.translate(frame: frame, from: external, to: laptop)

        #expect(moved.minX == laptop.minX + 8)
        #expect(moved.size == frame.size)
    }

    @Test func identityTranslateClampsOrphanedFrameOntoScreen() {
        // Display unplugged mid-run: source == target, so the translate is
        // an identity plus the clamp — each axis pins to the edge it
        // overflowed (here the right edge; the frame sat beyond maxX).
        let frame = CGRect(x: 3000, y: 200, width: 360, height: 480)
        let moved = PanelPlacement.translate(frame: frame, from: laptop, to: laptop)

        #expect(moved.maxX == laptop.maxX - 8)
        #expect(laptop.insetBy(dx: 8, dy: 8).contains(moved))
    }

    @Test func oversizedFrameKeepsTopLeftVisible() {
        // Taller than the laptop's visible area: the top edge (where the
        // search field lives) pins inside the screen and the bottom
        // overflows, never the reverse.
        let frame = CGRect(x: 1500, y: 210, width: 360, height: 1400)
        let moved = PanelPlacement.translate(frame: frame, from: external, to: laptop)

        #expect(moved.minX == laptop.minX + 60)
        #expect(moved.maxY == laptop.maxY - 8)
        #expect(moved.size == frame.size)
    }
}
