import SwiftUI

/// Full-panel overlay listing the keyboard surface. The table is maintained
/// by hand — a binding change lands here in the same PR, and the
/// manual-testing checklist pins the pairing.
struct ShortcutGuideView: View {
    /// Reflects the configured capture trigger, so a user who picked
    /// Control isn't told to double-tap Shift.
    let captureHint: String
    let onDismiss: () -> Void

    private static let groups: [(title: String, entries: [(keys: String, action: String)])] = [
        ("Notes", [
            ("␣", "Toggle done"),
            ("↩", "Edit note"),
            ("⌫", "Delete"),
            ("⌘Z", "Undo delete or merge"),
            ("⇧⌘Z", "Redo"),
            ("⇧⌘M", "Merge selected notes"),
            ("⌘E", "Expand or collapse a long note"),
        ]),
        ("Select", [
            ("↑ ↓", "Move selection"),
            ("⇧↑ ⇧↓", "Extend selection"),
            ("⌘A", "Select all"),
        ]),
        ("Copy", [
            ("⌘C", "Copy selected notes"),
            ("⇧⌘C", "Copy as a list"),
        ]),
        ("Panel", [
            ("⌘F", "Search"),
            ("⌘N", "New note"),
            ("⌘W", "Hide the panel"),
            ("⎋", "Clear a multi-selection, then filter, then hide"),
            ("⌘/", "This guide"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Text(captureHint + " — from any app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.caption.smallCaps().weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.entries, id: \.keys) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.keys)
                                    .font(.callout.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                    .frame(minWidth: 64, alignment: .leading)
                                Text(entry.action)
                                    .font(.callout)
                            }
                        }
                    }
                }
                Text("Esc or ⌘/ closes this guide.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .accessibilityAddTraits(.isModal)
    }
}
