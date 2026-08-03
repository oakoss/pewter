import CoreGraphics
@testable import PewterCore
import Testing

struct CaptureHUDPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 870)
    private let size = CGSize(width: 140, height: 32)

    @Test func centersBelowTheAnchor() {
        let anchor = CGRect(x: 500, y: 400, width: 200, height: 40)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen)

        #expect(frame.midX == anchor.midX)
        #expect(frame.maxY == anchor.minY - 8)
        #expect(frame.size == size)
    }

    @Test func flipsAboveNearTheBottomEdge() {
        let anchor = CGRect(x: 500, y: 20, width: 200, height: 16)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen)

        #expect(frame.minY == anchor.maxY + 8)
    }

    @Test func pointAnchorPlacesBelowThePoint() {
        // The mouse fallback: a zero-size anchor at the cursor.
        let anchor = CGRect(x: 700, y: 500, width: 0, height: 0)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen)

        #expect(frame.midX == anchor.midX)
        #expect(frame.maxY == anchor.minY - 8)
    }

    @Test func clampsToTheLeftEdge() {
        let anchor = CGRect(x: 0, y: 400, width: 10, height: 20)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen)

        #expect(frame.minX == screen.minX + 8)
    }

    @Test func clampsToTheRightEdge() {
        let anchor = CGRect(x: 1430, y: 400, width: 10, height: 20)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen)

        #expect(frame.maxX == screen.maxX - 8)
    }

    @Test func flippedPlacementStillClampsInsideTheTopEdge() {
        // An anchor spanning nearly the whole screen height: below has no
        // room, and the flipped spot overflows the top — the clamp wins.
        let anchor = CGRect(x: 500, y: 4, width: 200, height: 860)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen)

        #expect(frame.maxY == screen.maxY - 8)
        #expect(screen.insetBy(dx: 7, dy: 7).contains(frame))
    }

    @Test func nonZeroScreenOriginClampsAgainstScreenEdges() {
        // A secondary display to the left of the primary: negative X space,
        // non-zero Y origin.
        let external = CGRect(x: -1920, y: 100, width: 1920, height: 1060)
        let anchor = CGRect(x: -1918, y: 600, width: 10, height: 20)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: external)

        #expect(frame.minX == external.minX + 8)
        #expect(frame.maxY == anchor.minY - 8)
    }

    @Test func flipThresholdIsExact() {
        // Below-placement lands exactly at minY + inset: allowed, no flip;
        // one point lower must flip.
        let fits = CGRect(x: 500, y: 8 + 8 + 32, width: 200, height: 20)
        let fitted = CaptureHUDPlacement.frame(anchor: fits, size: size, screen: screen)
        #expect(fitted.minY == screen.minY + 8)
        #expect(fitted.maxY == fits.minY - 8)

        let overflows = fits.offsetBy(dx: 0, dy: -1)
        let flipped = CaptureHUDPlacement.frame(anchor: overflows, size: size, screen: screen)
        #expect(flipped.minY == overflows.maxY + 8)
    }

    @Test func honorsNonDefaultGapAndInset() {
        let anchor = CGRect(x: 20, y: 400, width: 10, height: 20)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: screen, gap: 20, inset: 4)

        #expect(frame.maxY == anchor.minY - 20)
        #expect(frame.minX == screen.minX + 4)
    }

    @Test func bottomEdgeFlipUsesTheScreenOriginNotZero() {
        let external = CGRect(x: -1920, y: 100, width: 1920, height: 1060)
        // Below-placement would land at y = 80, inside a zero-origin screen
        // but under this one's minY — the flip must trigger.
        let anchor = CGRect(x: -1000, y: 120, width: 10, height: 20)
        let frame = CaptureHUDPlacement.frame(anchor: anchor, size: size, screen: external)

        #expect(frame.minY == anchor.maxY + 8)
    }
}

struct CaptureHUDScreenIndexTests {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let external = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

    @Test func seamSpanningAnchorPicksTheGreaterOverlap() {
        let anchor = CGRect(x: 1400, y: 300, width: 200, height: 40)
        #expect(CaptureHUDPlacement.screenIndex(for: anchor, in: [primary, external]) == 1)
    }

    @Test func pointInsideAScreenMatchesIt() {
        let point = CGRect(x: 2000, y: 500, width: 0, height: 0)
        #expect(CaptureHUDPlacement.screenIndex(for: point, in: [primary, external]) == 1)
    }

    @Test func pointPinnedToTheTopEdgeStillMatches() {
        // NSEvent.mouseLocation reports exactly maxY for a cursor pinned to
        // the top of a screen; exclusive-edge intersection would miss it.
        let point = CGRect(x: 700, y: 900, width: 0, height: 0)
        #expect(CaptureHUDPlacement.screenIndex(for: point, in: [primary, external]) == 0)
    }

    @Test func pointPinnedToTheRightEdgeStillMatches() {
        let point = CGRect(x: 4000, y: 500, width: 0, height: 0)
        #expect(CaptureHUDPlacement.screenIndex(for: point, in: [primary, external]) == 1)
    }

    @Test func anchorOnNoScreenReturnsNil() {
        let anchor = CGRect(x: 9000, y: 9000, width: 10, height: 10)
        #expect(CaptureHUDPlacement.screenIndex(for: anchor, in: [primary, external]) == nil)
    }

    @Test func pointOnASharedSeamResolvesToTheFirstScreen() {
        // Callers pass NSScreen.screens, where index 0 is the primary; the
        // tie-break is part of the contract.
        let point = CGRect(x: 1440, y: 500, width: 0, height: 0)
        #expect(CaptureHUDPlacement.screenIndex(for: point, in: [primary, external]) == 0)
    }

    @Test func emptyScreenListReturnsNil() {
        let point = CGRect(x: 100, y: 100, width: 0, height: 0)
        #expect(CaptureHUDPlacement.screenIndex(for: point, in: []) == nil)
    }
}

struct CaptureHUDNormalizedAnchorTests {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func flipsTopLeftGlobalsToBottomLeft() {
        // 100pt down from the top in AX space → maxY 100pt under the top in
        // AppKit space.
        let axRect = CGRect(x: 300, y: 100, width: 200, height: 20)
        let anchor = CaptureHUDPlacement.normalizedAnchor(axRect: axRect, primaryHeight: 900, screens: [primary])

        #expect(anchor == CGRect(x: 300, y: 780, width: 200, height: 20))
    }

    @Test func secondaryScreenBelowThePrimaryStaysOnIt() {
        // A display arranged under the primary: AX y beyond the primary's
        // height converts to negative AppKit y.
        let below = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        let axRect = CGRect(x: 500, y: 1000, width: 100, height: 20)
        let anchor = CaptureHUDPlacement.normalizedAnchor(
            axRect: axRect,
            primaryHeight: 900,
            screens: [primary, below]
        )

        #expect(anchor == CGRect(x: 500, y: -120, width: 100, height: 20))
    }

    @Test func zeroHeightRectIsRejected() {
        let axRect = CGRect(x: 300, y: 100, width: 200, height: 0)
        #expect(CaptureHUDPlacement.normalizedAnchor(axRect: axRect, primaryHeight: 900, screens: [primary]) == nil)
    }

    @Test func zeroWidthCaretIsAccepted() {
        // The zero-area converted rect must survive validation via the
        // containment fallback, with the flip intact.
        let axRect = CGRect(x: 300, y: 100, width: 0, height: 18)
        let anchor = CaptureHUDPlacement.normalizedAnchor(axRect: axRect, primaryHeight: 900, screens: [primary])
        #expect(anchor == CGRect(x: 300, y: 782, width: 0, height: 18))
    }

    @Test func partiallyOffscreenRectIsAccepted() {
        // A selection in a window hanging off the screen edge is a real
        // anchor; validation requires overlap, not full containment.
        let axRect = CGRect(x: 1400, y: 100, width: 200, height: 20)
        let anchor = CaptureHUDPlacement.normalizedAnchor(axRect: axRect, primaryHeight: 900, screens: [primary])
        #expect(anchor != nil)
    }

    @Test func farOffscreenRectIsRejected() {
        let axRect = CGRect(x: 90000, y: 100, width: 200, height: 20)
        #expect(CaptureHUDPlacement.normalizedAnchor(axRect: axRect, primaryHeight: 900, screens: [primary]) == nil)
    }

    @Test func emptyScreenListRejectsEverything() {
        let axRect = CGRect(x: 300, y: 100, width: 200, height: 20)
        #expect(CaptureHUDPlacement.normalizedAnchor(axRect: axRect, primaryHeight: 900, screens: []) == nil)
    }
}
