import SmartListCore
import SwiftUI

struct ItemRow: View {
    let item: Item
    let isSelected: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    var editorFocus: FocusState<PanelRootView.Field?>.Binding
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    let onCopy: () -> Void
    let onCopyList: () -> Void
    let onDelete: () -> Void

    @State private var editText = ""
    @State private var isHovering = false
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            checkbox
            content
            Spacer(minLength: 0)
            if isHovering || showsCopied, !isEditing {
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
        .onTapGesture(count: 2) { onBeginEdit() }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Copy") { onCopy() }
            Button("Copy as List") { onCopyList() }
            Divider()
            Button(item.done ? "Mark as Not Done" : "Mark as Done") { onToggle() }
            Button("Edit") { onBeginEdit() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        if isHighlighted {
            AnyShapeStyle(Color.accentColor.opacity(0.25))
        } else if isSelected {
            AnyShapeStyle(.selection.opacity(0.35))
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
        .accessibilityLabel("Copy")
        .help("Copy — ⌥ click to also mark as done")
        .transition(.opacity)
    }

    private var checkbox: some View {
        Button(action: onToggle) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
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
            Text(markdownText)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .help(Text(item.createdAt, format: .dateTime))
        }
    }

    private var markdownText: AttributedString {
        (try? AttributedString(
            markdown: item.text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(item.text)
    }
}
