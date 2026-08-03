import AppKit
import os
import PewterCore
import SwiftUI

/// Note text with tappable links. Only link glyphs are hit-testable — every
/// other click falls through to the row behind it, so selecting and
/// double-click-to-edit keep working over plain text while a link click
/// opens the destination.
struct LinkText: NSViewRepresentable {
    let attributed: NSAttributedString
    let clamped: Bool

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        apply(to: view)
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: LinkTextView) {
        let lines = clamped ? LinkTextView.clampLineCount : 0
        if let container = view.textContainer, container.maximumNumberOfLines != lines {
            container.maximumNumberOfLines = lines
            // Changing the clamp alone doesn't invalidate TextKit's cached
            // layout; without this the next measurement returns the old height.
            view.layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: view.textStorage?.length ?? 0),
                actualCharacterRange: nil
            )
        }
        guard let storage = view.textStorage else {
            assertionFailure("NSTextView without a text storage")
            return
        }
        guard !storage.isEqual(to: attributed) else { return }
        storage.setAttributedString(attributed)
        view.setAccessibilityLabel(attributed.string)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        nsView.size(forWidth: proposal.width)
    }
}

final class LinkTextView: NSTextView {
    /// Rows clamp to this many lines unless expanded.
    static let clampLineCount = 6

    private var pressedLink: (url: URL, range: NSRange)?

    override var acceptsFirstResponder: Bool {
        false
    }

    /// The panel is non-activating, so the first click must act.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return link(at: convert(point, from: superview)) == nil ? nil : self
    }

    /// Open on mouse-up inside the same link that took the mouse-down — a
    /// press that drags off the link is a cancel, matching button behavior.
    /// The comparison is the link's attribute range, not the character
    /// under the cursor: normal clicks drift a pixel or two, and crossing
    /// a character boundary inside one link must still count.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        pressedLink = link(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedLink = nil }
        // A double-click delivers two full down/up pairs; without this the
        // second up would open the destination twice. The URL equality
        // backs up the range match: an external edit can swap the storage
        // mid-press, and a coincidentally identical range must not open a
        // destination the user never pressed.
        guard event.clickCount == 1,
              let pressed = pressedLink,
              let current = link(at: convert(event.locationInWindow, from: nil)),
              current.range == pressed.range, current.url == pressed.url
        else { return }
        open(current.url)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = link(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Link", action: #selector(openLink(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = hit.url
        menu.addItem(open)
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = hit.url
        menu.addItem(copy)
        return menu
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Pasteboard.write(url.absoluteString)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            // Every hit-test said "link" — a silent no-op here would read
            // as a dead click with nothing to debug. The scheme is public;
            // the error description is explicitly private because it can
            // embed the URL — note content — and own-process log reads
            // (Copy Diagnostics) render default-privacy values verbatim.
            //
            // `Logger.panel`, not a property on this class: the closure is
            // Sendable, and statics on a @MainActor class are isolated.
            Logger.panel
                .error(
                    "failed to open \(url.scheme ?? "?", privacy: .public) link: \(error.localizedDescription, privacy: .private)"
                )
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NSSound.beep() }
            }
        }
    }

    private var cursorTracking: NSTrackingArea?

    /// Not cursor rects: those operate only while the window is key, and
    /// this non-activating panel almost never is. An always-active tracking
    /// area drives the pointing hand the same way the SwiftUI controls'
    /// hover does — and because `link(at:)` is asked live per move, the
    /// cursor and the hit test cannot disagree.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking {
            removeTrackingArea(cursorTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let overLink = link(at: convert(event.locationInWindow, from: nil)) != nil
        (overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    func size(forWidth width: CGFloat?) -> CGSize? {
        guard let layoutManager, let textContainer else { return nil }
        // The zero-width probe asks for the minimum; wrapping text can
        // compress to nothing, and a rigid answer here makes the HStack
        // split the row's width instead of granting it all.
        if let width, width <= 0 {
            return .zero
        }
        // .infinity and nil both mean "ideal" — measure unconstrained; a
        // non-finite container width is undefined in TextKit.
        let resolved = width.flatMap { $0.isFinite ? $0 : nil }
        textContainer.size = NSSize(
            width: resolved ?? .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).size
        return CGSize(
            width: resolved ?? used.width.rounded(.up),
            height: used.height.rounded(.up)
        )
    }

    /// The link under `point` (view coordinates), nil over plain text. The
    /// layout manager clamps a miss to the nearest character, so the glyph's
    /// actual bounds must confirm the hit — clicking past a line's end is
    /// not a click on its last link.
    private func link(at point: NSPoint) -> (url: URL, range: NSRange)? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let container = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let index = layoutManager.characterIndex(
            for: container,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let bounds = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        var effective = NSRange(location: NSNotFound, length: 0)
        // longestEffectiveRange, not effectiveRange: a styled link splits
        // into font runs, and the plain variant can stop at a run boundary
        // — press and release inside one link must agree on its range.
        guard bounds.contains(container),
              let value = storage.attribute(
                  .link,
                  at: index,
                  longestEffectiveRange: &effective,
                  in: NSRange(location: 0, length: storage.length)
              ),
              let url = Self.url(from: value)
        else { return nil }
        return (url, effective)
    }

    private static func url(from value: Any?) -> URL? {
        value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }
}
