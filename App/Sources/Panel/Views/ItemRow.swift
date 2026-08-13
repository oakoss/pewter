import PewterCore
import SwiftUI

/// Actions that act on this row alone, regardless of the selection.
struct ItemRowActions {
    let toggle: () -> Void
    let toggleExpand: () -> Void
    let select: () -> Void
    let beginEdit: () -> Void
    let commitEdit: (String) -> Void
    let cancelEdit: () -> Void
    let copy: () -> Void
    /// Row-scoped, unlike the menu's delete: the VoiceOver row action
    /// presents itself as acting on the element under the cursor and must
    /// not silently widen to the selection.
    let delete: () -> Void
}

/// Selection-scoped actions plus the state that presents them: they act on
/// the whole selection when this row is part of it, on the row alone
/// otherwise. Surfaced via the context menu.
struct ItemRowMenu {
    /// Whether the done action marks its targets done (vs not done) —
    /// computed over the whole selection when this row is in it.
    let marksDone: Bool
    let canMerge: Bool
    let copy: () -> Void
    let copyAsList: () -> Void
    let toggleDone: () -> Void
    let merge: () -> Void
    let delete: () -> Void
}

struct ItemRow: View {
    let item: Item
    let isSelected: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    /// Text from an edit the store refused, so re-opening the editor restores
    /// what the user typed rather than what is still in the document. Owned by
    /// the panel: this row is torn down and rebuilt across a refusal, and
    /// anything held here would not survive it.
    let pendingEditText: String?
    let isExpanded: Bool
    var editorFocus: FocusState<PanelRootView.Field?>.Binding
    let actions: ItemRowActions
    let menu: ItemRowMenu

    @State private var editText = ""
    @State private var isHovering = false
    @State private var textWidth: CGFloat = 0
    /// Cached measurement, recomputed only when its explicit inputs (text
    /// width, note text) change — measuring in body would re-lay-out every
    /// row on every render, and keying on inputs can't strand a stale
    /// verdict the way view-layout reporting could.
    @State private var isTruncated = false
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            checkbox
            content
            Spacer(minLength: 0)
            if !isEditing {
                copyButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundStyle)
        )
        .animation(.easeOut(duration: 0.3), value: isHighlighted)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        // A roleless combined row exposes as AXUnknown, which VoiceOver
        // skips on hover and won't traverse. Activation selects; the named
        // actions carry the other verbs. The trait drops and the action
        // guards while the inline editor is up, or activating the row
        // would move focus off the editor and discard the edit. One traits
        // call: splitting these across two accessibilityAddTraits calls
        // emptied the selected row's label (verified by AX dump).
        .accessibilityAddTraits(rowTraits)
        .accessibilityAction {
            if !isEditing {
                actions.select()
            }
        }
        // Done state as a value, not strikethrough alone — and every mouse
        // route (tap to select, double-tap to edit, hover copy, menu
        // delete) as a named action, since the combined row swallows the
        // gestures VoiceOver can't reach.
        .accessibilityValue(item.done ? "Done" : "Not done")
        .accessibilityAction(named: "Edit") { actions.beginEdit() }
        .accessibilityAction(named: item.done ? "Mark as Not Done" : "Mark as Done") { actions.toggle() }
        .accessibilityAction(named: "Copy") { actions.copy() }
        .accessibilityActions {
            // Only long notes can visibly expand; a short note would toggle
            // hidden state to no effect.
            if isTruncated {
                Button(isExpanded ? "Collapse" : "Expand") { actions.toggleExpand() }
            }
        }
        .accessibilityAction(named: "Delete") { actions.delete() }
        .onTapGesture(count: 2) { actions.beginEdit() }
        .onTapGesture { actions.select() }
        .contextMenu {
            Button("Copy") { menu.copy() }
            Button("Copy as List") { menu.copyAsList() }
            Divider()
            Button(menu.marksDone ? "Mark as Done" : "Mark as Not Done") { menu.toggleDone() }
            // Row-scoped even from the menu: inline editing targets a
            // single row.
            Button("Edit") { actions.beginEdit() }
            // Always visible, disabled unless this row is part of a
            // multi-selection: a stable menu teaches the feature; hiding it
            // hides that it exists.
            Button("Merge Notes") { menu.merge() }
                .disabled(!menu.canMerge)
            Divider()
            Button("Delete", role: .destructive) { menu.delete() }
        }
    }

    private var rowTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = []
        if !isEditing {
            traits.formUnion(.isButton)
        }
        if isSelected {
            traits.formUnion(.isSelected)
        }
        return traits
    }

    private var backgroundStyle: AnyShapeStyle {
        if isHighlighted {
            // Stronger than the selected fill or the capture flash reads as
            // a slight dimming on an already-selected row.
            AnyShapeStyle(Color.accentColor.opacity(0.45))
        } else if isSelected {
            // Explicit accent, not `.selection`: that style drops to its
            // unemphasized appearance whenever the app is inactive, and this
            // panel is non-activating — the app is inactive almost always.
            AnyShapeStyle(Color.accentColor.opacity(0.3))
        } else {
            AnyShapeStyle(.background.opacity(0.6))
        }
    }

    private var copyButton: some View {
        Button {
            actions.copy()
            // Option-click: the "I'm sending this off, we're finished" move.
            if NSEvent.modifierFlags.contains(.option), !item.done {
                actions.toggle()
            }
            showsCopied = true
            // Cancel the previous reset or a second quick copy loses its
            // checkmark early.
            copiedResetTask?.cancel()
            copiedResetTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                showsCopied = false
            }
        } label: {
            Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(showsCopied ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // Faded rather than removed when idle: inserting the button on
        // hover narrows the text column, re-wraps the row, and jiggles
        // every row below it.
        .opacity(showsCopyButton ? 1 : 0)
        .allowsHitTesting(showsCopyButton)
        // Unconditionally, not on hover: the row's Copy action covers
        // VoiceOver, and a pointer resting on the row would otherwise
        // surface a second Copy. The label still matters — VO's pointer
        // hit-testing can land on the control directly, and an unlabeled
        // icon button speaks as a bare "button".
        .accessibilityHidden(true)
        .accessibilityLabel("Copy")
        .help("Copy — ⌥ click to also mark as done")
    }

    private var showsCopyButton: Bool {
        isHovering || showsCopied
    }

    private var checkbox: some View {
        Button(action: actions.toggle) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // The combined row carries done state as its value and toggling as
        // a named action; exposing the button too would double-speak. The
        // label covers VO pointer hits, which bypass the hidden flag.
        .accessibilityHidden(true)
        .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextField("", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused(editorFocus, equals: .editor)
                .onAppear { editText = pendingEditText ?? item.text }
                .onSubmit { actions.commitEdit(editText) }
                .onKeyPress(.escape) {
                    actions.cancelEdit()
                    return .handled
                }
        } else {
            let rendered = displayText
            VStack(alignment: .leading, spacing: 4) {
                LinkText(attributed: rendered, clamped: !isExpanded)
                    // A representable exposes no text baseline, so the row's
                    // firstTextBaseline alignment would fall back to an edge
                    // and open a gap above the text; hand it the first line's
                    // real baseline.
                    .alignmentGuide(.firstTextBaseline) { _ in
                        NSFont.preferredFont(forTextStyle: .body).ascender
                    }
                    // Without this, VoiceOver announces the row's buttons but
                    // not the note; it must read the rendered string, not raw
                    // markdown.
                    .accessibilityLabel(rendered.string)
                    .help(Text(item.createdAt, format: .dateTime))
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                // The explicit recompute covers reappearing
                                // after an edit: the editor removes this
                                // branch and its observers, so a committed
                                // text change arrives with the width — and
                                // therefore onChange — unchanged.
                                .onAppear {
                                    textWidth = geometry.size.width
                                    updateTruncation()
                                }
                                .onChange(of: geometry.size.width) { _, width in
                                    textWidth = width
                                }
                        }
                    )
                    .onChange(of: textWidth) { _, _ in updateTruncation() }
                    .onChange(of: item.text) { _, _ in updateTruncation() }
                // True while expanded too ("Show less" keeps its place),
                // false for a short note Cmd+E swept into a selection.
                if isTruncated {
                    disclosureButton
                }
            }
        }
    }

    private func updateTruncation() {
        isTruncated = TextTruncation.clampHidesText(
            displayText,
            width: textWidth,
            lineLimit: LinkTextView.clampLineCount
        )
    }

    private var disclosureButton: some View {
        Button(action: actions.toggleExpand) {
            Label(
                isExpanded ? "Show less" : "Show more",
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // The row's Expand/Collapse action covers VoiceOver; exposing the
        // button too would surface the verb twice.
        .accessibilityHidden(true)
        // No ⌘E hint: the shortcut acts on the selection, and the chevron's
        // row isn't necessarily in it.
        .help(isExpanded ? "Collapse" : "Expand")
    }

    private var displayText: NSAttributedString {
        DisplayTextCache.rendered(text: item.text, done: item.done)
    }
}

/// Core's parse (`InlineMarkdown`) resolved to AppKit attributes — the link
/// hit-testing lives in an `NSTextView`, which reads font traits, not
/// presentation intents. Cached across rows and renders: the eager list
/// re-renders every row on each keystroke, and parse + attributed assembly
/// measured ~22 ms per full pass at 300 notes (pw-6i8) against 0.1 ms for
/// the same pass memoized. The key carries everything the output depends
/// on except appearance: the semantic colors are dynamic providers that
/// resolve against the drawing appearance, so a cached string follows a
/// light/dark switch on its own. The base font size is keyed, so a system
/// text-size change can't serve stale fonts.
@MainActor
private enum DisplayTextCache {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 2000
        // Entries scale with note length (key and value each hold the
        // text), so bound bytes too — 8 MB of source text, evicted LRU,
        // on top of NSCache's own memory-pressure eviction.
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    static func rendered(text: String, done: Bool) -> NSAttributedString {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let key = "\(base.pointSize)|\(done ? 1 : 0)|\(text)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        // Immutable copy: the cached instance is shared across rows and
        // long-lived, so it must not be the mutable builder result.
        let built = NSAttributedString(
            attributedString: build(text: text, done: done, base: base)
        )
        cache.setObject(built, forKey: key, cost: text.utf8.count)
        return built
    }

    private static func build(text: String, done: Bool, base: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in InlineMarkdown.runs(from: text) {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: done ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            if done || run.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            var font = base
            if run.code {
                font = .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            }
            var traits: NSFontTraitMask = []
            if run.bold {
                traits.insert(.boldFontMask)
            }
            if run.italic {
                traits.insert(.italicFontMask)
            }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            attributes[.font] = font

            if let link = run.link.flatMap(URL.init(string:)) {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}
