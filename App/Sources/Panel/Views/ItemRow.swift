import PewterCore
import SwiftUI

struct ItemRow: View {
    let item: Item
    let isSelected: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    let isExpanded: Bool
    /// Whether the context menu's done action marks its targets done (vs not
    /// done) — computed over the whole selection when this row is in it.
    let menuMarksDone: Bool
    var editorFocus: FocusState<PanelRootView.Field?>.Binding
    let onToggle: () -> Void
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    let onCopy: () -> Void
    let onMenuCopy: () -> Void
    let onMenuCopyList: () -> Void
    let onMenuToggle: () -> Void
    let canMerge: Bool
    let onMenuMerge: () -> Void
    /// Row-scoped, unlike `onMenuDelete`: the VoiceOver row action presents
    /// itself as acting on the element under the cursor and must not
    /// silently widen to the selection.
    let onDelete: () -> Void
    let onMenuDelete: () -> Void

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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Done state as a value, not strikethrough alone — and every mouse
        // route (tap to select, double-tap to edit, hover copy, menu
        // delete) as a named action, since the combined row swallows the
        // gestures VoiceOver can't reach.
        .accessibilityValue(item.done ? "Done" : "Not done")
        .accessibilityAction(named: "Select") { onSelect() }
        .accessibilityAction(named: "Edit") { onBeginEdit() }
        .accessibilityAction(named: item.done ? "Mark as Not Done" : "Mark as Done") { onToggle() }
        .accessibilityAction(named: "Copy") { onCopy() }
        .accessibilityAction(named: "Delete") { onDelete() }
        .onTapGesture(count: 2) { onBeginEdit() }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Copy") { onMenuCopy() }
            Button("Copy as List") { onMenuCopyList() }
            Divider()
            Button(menuMarksDone ? "Mark as Done" : "Mark as Not Done") { onMenuToggle() }
            Button("Edit") { onBeginEdit() }
            // Always visible, disabled unless this row is part of a
            // multi-selection: a stable menu teaches the feature; hiding it
            // hides that it exists.
            Button("Merge Notes") { onMenuMerge() }
                .disabled(!canMerge)
            Divider()
            Button("Delete", role: .destructive) { onMenuDelete() }
        }
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
            onCopy()
            // Option-click: the "I'm sending this off, we're finished" move.
            if NSEvent.modifierFlags.contains(.option), !item.done {
                onToggle()
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
        // surface a second Copy.
        .accessibilityHidden(true)
        .help("Copy — ⌥ click to also mark as done")
    }

    private var showsCopyButton: Bool {
        isHovering || showsCopied
    }

    private var checkbox: some View {
        Button(action: onToggle) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // The combined row carries done state as its value and toggling as
        // a named action; exposing the button too would double-speak.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextField("", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused(editorFocus, equals: .editor)
                .onAppear { editText = item.text }
                .onSubmit { onCommitEdit(editText) }
                .onKeyPress(.escape) {
                    onCancelEdit()
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
        Button(action: onToggleExpand) {
            Label(
                isExpanded ? "Show less" : "Show more",
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // No ⌘E hint: the shortcut acts on the selection, and the chevron's
        // row isn't necessarily in it.
        .help(isExpanded ? "Collapse" : "Expand")
    }

    /// Core's parse (`InlineMarkdown`) resolved to AppKit attributes —
    /// the link hit-testing lives in an `NSTextView`, which reads font
    /// traits, not presentation intents.
    private var displayText: NSAttributedString {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()
        for run in InlineMarkdown.runs(from: item.text) {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: item.done ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            if item.done || run.strikethrough {
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
