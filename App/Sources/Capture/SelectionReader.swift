import AppKit
import ApplicationServices
import os
import PewterCore

/// Reads the selected text of the frontmost app via the Accessibility API —
/// fast, invisible, no clipboard side effects. Returns nil for apps that
/// don't expose their selection at all; the pasteboard fallback covers those.
struct SelectionReader: SelectionReading {
    private static let logger = Logger.capture

    @MainActor
    func readSelection() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // AX calls block until the target app answers; without a timeout an
        // unresponsive frontmost app would beachball us for seconds.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        // Fast path: the focused element carries the selection (standard
        // text fields, most native apps).
        if let focused = element(of: kAXFocusedUIElementAttribute, on: appElement) {
            if let text = selection(on: focused) {
                return text
            }
            // A focused element that SUPPORTS selected text but has none is
            // the user's real text context — walking now would return some
            // background pane's retained (stale) selection. Only walk when
            // the focused element has no notion of selected text at all.
            var probe: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &probe) == .success {
                return nil
            }
        }

        // Some apps hold the selection on an element that is never focused —
        // GPU terminals like Ghostty expose the buffer as a text area nested
        // under a scroll area while focus sits on the window. Walk the
        // focused window breadth-first, bounded, for any selected text. Also
        // rescues them from the pasteboard fallback, whose synthetic Cmd+C
        // they ignore.
        guard let window = element(of: kAXFocusedWindowAttribute, on: appElement) else { return nil }
        var queue = [window]
        var visited = 0
        // Count-bounded AND time-bounded: 80 elements at the 0.1 s per-call
        // timeout could otherwise stall the gesture for seconds.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while !queue.isEmpty, visited < 80, ContinuousClock.now < deadline {
            let current = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(current, 0.1)

            if let text = selection(on: current) {
                return text
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
        return nil
    }

    /// Screen bounds of the focused element's selected text in AppKit
    /// bottom-left coordinates (AX reports top-left-origin globals). nil
    /// when the focused element exposes no usable bounds — window-walk and
    /// pasteboard captures land here — and the caller anchors on the mouse
    /// instead.
    @MainActor
    func selectionBounds() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Tighter budget than the capture read: the anchor is cosmetic, and
        // an app slow to answer AX (a busy GPU terminal) must not delay the
        // feedback the anchor positions — give up fast, fall back to the
        // mouse.
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        guard let focused = element(of: kAXFocusedUIElementAttribute, on: appElement) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.1)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID(),
            AXValueGetType(unsafeDowncast(rangeRef as AnyObject, to: AXValue.self)) == .cfRange
        else { return nil }

        var boundsRef: CFTypeRef?
        let boundsError = AXUIElementCopyParameterizedAttributeValue(
            focused,
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

    /// Non-empty selected text of one element, via AXSelectedText or the
    /// parameterized string-for-range lookup some WebKit views require.
    private func selection(on element: AXUIElement) -> String? {
        if let text = string(of: kAXSelectedTextAttribute, on: element), !text.isEmpty {
            return text
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID(),
            AXValueGetType(unsafeDowncast(rangeRef as AnyObject, to: AXValue.self)) == .cfRange
        else { return nil }

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

        return text
    }

    private func element(of attribute: String, on parent: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
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
