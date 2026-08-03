import CoreGraphics
@testable import PewterCore
import Testing

struct ScreenGeometryClampTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 870)

    @Test func fittingRectInsideBoundsIsUntouched() {
        let rect = CGRect(x: 500, y: 300, width: 360, height: 480)
        #expect(ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: .topLeft) == rect)
        #expect(ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: .bottomLeft) == rect)
    }

    @Test func overflowPinsToTheNearestEdgeWithInset() {
        let rect = CGRect(x: -50, y: 900, width: 360, height: 480)
        let clamped = ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: .topLeft)

        #expect(clamped.minX == bounds.minX + 8)
        #expect(clamped.maxY == bounds.maxY - 8)
        #expect(clamped.size == rect.size)
    }

    @Test func oversizedRectKeepsTheTopLeftCorner() {
        // Taller than the bounds: the top edge pins inside and the bottom
        // overflows — the panel's controls stay reachable.
        let rect = CGRect(x: 100, y: 100, width: 360, height: 1400)
        let clamped = ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: .topLeft)

        #expect(clamped.maxY == bounds.maxY - 8)
        #expect(clamped.minY < bounds.minY)
    }

    @Test func oversizedRectKeepsTheBottomLeftCorner() {
        let rect = CGRect(x: 100, y: 100, width: 360, height: 1400)
        let clamped = ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: .bottomLeft)

        #expect(clamped.minY == bounds.minY + 8)
        #expect(clamped.maxY > bounds.maxY)
    }

    @Test func overWideRectKeepsTheLeftEdgeForBothCorners() {
        let rect = CGRect(x: 800, y: 300, width: 1600, height: 480)

        for corner: ScreenGeometry.Corner in [.topLeft, .bottomLeft] {
            let clamped = ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: corner)
            #expect(clamped.minX == bounds.minX + 8)
            #expect(clamped.maxX > bounds.maxX)
        }
    }

    @Test func nonZeroOriginBoundsClampAgainstTheirOwnEdges() {
        let external = CGRect(x: -1920, y: 100, width: 1920, height: 1060)
        let rect = CGRect(x: -2000, y: 0, width: 360, height: 480)

        // A fitting rect pins to the same origin under both corners — the
        // corner only decides oversized behavior.
        for corner: ScreenGeometry.Corner in [.topLeft, .bottomLeft] {
            let clamped = ScreenGeometry.clamp(rect, inside: external, inset: 8, keeping: corner)
            #expect(clamped.minX == external.minX + 8)
            #expect(clamped.minY == external.minY + 8)
        }
    }

    @Test func topLeftTopOverflowClampsAgainstNonZeroOriginBounds() {
        // The topLeft y-branch has its own min/max nesting; a regression
        // substituting height for maxY would only show on non-zero origins.
        let external = CGRect(x: -1920, y: 100, width: 1920, height: 1060)
        let rect = CGRect(x: -1000, y: 1200, width: 360, height: 480)
        let clamped = ScreenGeometry.clamp(rect, inside: external, inset: 8, keeping: .topLeft)

        #expect(clamped.maxY == external.maxY - 8)
    }

    @Test func bottomLeftFittingRectStillPinsTheTopEdge() {
        // The corner decides oversized behavior only; a fitting rect above
        // the bounds pins back inside regardless.
        let rect = CGRect(x: 500, y: 900, width: 360, height: 480)
        let clamped = ScreenGeometry.clamp(rect, inside: bounds, inset: 8, keeping: .bottomLeft)

        #expect(clamped.maxY == bounds.maxY - 8)
    }
}

struct ScreenGeometryScreenIndexTests {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let external = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

    @Test func seamSpanningAnchorPicksTheGreaterOverlap() {
        let anchor = CGRect(x: 1400, y: 300, width: 200, height: 40)
        #expect(ScreenGeometry.screenIndex(for: anchor, in: [primary, external]) == 1)
    }

    @Test func pointInsideAScreenMatchesIt() {
        let point = CGRect(x: 2000, y: 500, width: 0, height: 0)
        #expect(ScreenGeometry.screenIndex(for: point, in: [primary, external]) == 1)
    }

    @Test func pointPinnedToTheTopEdgeStillMatches() {
        // NSEvent.mouseLocation reports exactly maxY for a cursor pinned to
        // the top of a screen; exclusive-edge intersection would miss it.
        let point = CGRect(x: 700, y: 900, width: 0, height: 0)
        #expect(ScreenGeometry.screenIndex(for: point, in: [primary, external]) == 0)
    }

    @Test func pointPinnedToTheRightEdgeStillMatches() {
        let point = CGRect(x: 4000, y: 500, width: 0, height: 0)
        #expect(ScreenGeometry.screenIndex(for: point, in: [primary, external]) == 1)
    }

    @Test func anchorOnNoScreenReturnsNil() {
        let anchor = CGRect(x: 9000, y: 9000, width: 10, height: 10)
        #expect(ScreenGeometry.screenIndex(for: anchor, in: [primary, external]) == nil)
    }

    @Test func positiveAreaRectSharingAnEdgeMatchesNoScreen() {
        // Zero-area intersection with a midpoint outside: the containment
        // fallback is for zero-area anchors only. A panel frame parked
        // beside a screen must not inherit a spurious source screen.
        let adjacent = CGRect(x: 4000, y: 300, width: 360, height: 480)
        #expect(ScreenGeometry.screenIndex(for: adjacent, in: [primary, external]) == nil)
    }

    @Test func pointOnASharedSeamResolvesToTheFirstScreen() {
        // Callers pass NSScreen.screens, where index 0 is the primary; the
        // tie-break is part of the contract.
        let point = CGRect(x: 1440, y: 500, width: 0, height: 0)
        #expect(ScreenGeometry.screenIndex(for: point, in: [primary, external]) == 0)
    }

    @Test func emptyScreenListReturnsNil() {
        let point = CGRect(x: 100, y: 100, width: 0, height: 0)
        #expect(ScreenGeometry.screenIndex(for: point, in: []) == nil)
    }
}
