import AppKit
import ApplicationServices
import os
import PewterCore

/// Reads the selected text of the frontmost app via the Accessibility API —
/// fast, invisible, no clipboard side effects — together with the screen
/// anchor for capture feedback, from the same element and range. Reports
/// no selection for apps that don't expose theirs at all; the pasteboard
/// fallback covers those.
struct SelectionReader: SelectionReading {
    private static let logger = Logger.capture

    private static let axReadTimeout: Float = 0.25
    private static let axWalkTimeout: Float = 0.1
    /// An anchor must not stall the capture it decorates.
    private static let axAnchorTimeout: Float = 0.1

    @MainActor
    func readSelection() -> SelectionRead {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .noSelection(caret: nil) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // AX calls block until the target app answers; without a timeout an
        // unresponsive frontmost app would beachball us for seconds.
        AXUIElementSetMessagingTimeout(appElement, Self.axReadTimeout)

        // Fast path: the focused element carries the selection (standard
        // text fields, most native apps).
        if let focused = element(of: kAXFocusedUIElementAttribute, on: appElement) {
            if let read = selection(on: focused) {
                return read
            }
            // A focused element that SUPPORTS selected text but has none is
            // the user's real text context — walking now would return some
            // background pane's retained (stale) selection. Only walk when
            // the focused element has no notion of selected text at all.
            // The empty range's bounds are the caret: the right anchor for
            // nothing-selected feedback.
            var probe: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &probe) == .success {
                return .noSelection(caret: anchor(on: focused))
            }
        }

        // Some apps hold the selection on an element that is never focused —
        // GPU terminals like Ghostty expose the buffer as a text area nested
        // under a scroll area while focus sits on the window. Walk the
        // focused window breadth-first, bounded, for any selected text. Also
        // rescues them from the pasteboard fallback, whose synthetic Cmd+C
        // they ignore.
        guard let window = element(of: kAXFocusedWindowAttribute, on: appElement) else {
            return .noSelection(caret: nil)
        }
        var queue = [window]
        var visited = 0
        // Count-bounded AND time-bounded: 80 elements at the 0.1 s per-call
        // timeout could otherwise stall the gesture for seconds.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while !queue.isEmpty, visited < 80, ContinuousClock.now < deadline {
            let current = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(current, Self.axWalkTimeout)

            if let read = selection(on: current) {
                return read
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement]
            {
                queue.append(contentsOf: children)
            }
        }
        if !queue.isEmpty {
            // Distinguishes "walked everything, no selection" from "gave up
            // early" when debugging why the AX tier misses an app.
            Self.logger.debug("AX walk hit element cap with \(queue.count) unvisited; falling back")
        }
        return .noSelection(caret: nil)
    }

    /// Non-empty selected text of one element with its screen anchor, via
    /// AXSelectedText or the parameterized string-for-range lookup some
    /// WebKit views require.
    private func selection(on element: AXUIElement) -> SelectionRead? {
        if let text = string(of: kAXSelectedTextAttribute, on: element), !text.isEmpty {
            return .selection(text: text, bounds: anchor(on: element))
        }

        guard let rangeRef = selectedRange(on: element) else { return nil }

        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeRef,
            &textRef
        ) == .success,
            let text = textRef as? String,
            !text.isEmpty
        else { return nil }

        return .selection(text: text, bounds: anchor(on: element, range: rangeRef))
    }

    /// The element's selected-text range, validated as an AXValue-wrapped
    /// CFRange. nil covers "unsupported" and "answered with the wrong
    /// type" alike — the expected-common case for non-text elements.
    private func selectedRange(on element: AXUIElement) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &ref
        ) == .success,
            let ref,
            CFGetTypeID(ref) == AXValueGetTypeID(),
            AXValueGetType(unsafeDowncast(ref as AnyObject, to: AXValue.self)) == .cfRange
        else { return nil }
        return ref
    }

    /// Screen anchor for the element's selected range — the caret when the
    /// range is empty — normalized to AppKit coordinates. nil when the app
    /// exposes no usable bounds; feedback then anchors on the mouse.
    private func anchor(on element: AXUIElement, range: CFTypeRef? = nil) -> CGRect? {
        // Tighter budget than the capture read: the anchor is cosmetic,
        // and an app slow to answer AX must not stall the capture it
        // decorates. Safe to narrow here — these are the element's last
        // AX calls on every path.
        AXUIElementSetMessagingTimeout(element, Self.axAnchorTimeout)

        guard let rangeRef = range ?? selectedRange(on: element) else {
            // Anomalous when reached: both callers already proved the
            // element supports selected text.
            Self.logger.debug("selected-range fetch for anchor failed; anchoring on mouse")
            return nil
        }

        var boundsRef: CFTypeRef?
        let boundsError = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRef,
            &boundsRef
        )
        guard boundsError == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else {
            // Logs the AXError so a transient timeout can be told apart
            // from an app that never supports this lookup.
            Self.logger.debug("selection bounds lookup failed (AXError \(boundsError.rawValue)); anchoring on mouse")
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(boundsRef as AnyObject, to: AXValue.self), .cgRect, &rect) else {
            Self.logger.debug("selection bounds AXValue was not a rect; anchoring on mouse")
            return nil
        }

        guard let primary = NSScreen.screens.first,
              let converted = CaptureHUDPlacement.normalizedAnchor(
                  axRect: rect,
                  primaryHeight: primary.frame.maxY,
                  screens: NSScreen.screens.map(\.frame)
              )
        else {
            // The raw rect shows whether the app answered without data
            // (zero height) or with a rect on no screen — geometry only,
            // safe at default privacy.
            Self.logger.debug("selection bounds rejected (\(String(describing: rect))); anchoring on mouse")
            return nil
        }
        return converted
    }

    private func element(of attribute: String, on parent: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.axReadTimeout)
        return element
    }

    private func string(of attribute: String, on element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }
}
