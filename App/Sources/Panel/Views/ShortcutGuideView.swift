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

    private static let spokenKeys: [Character: String] = [
        "⌘": "Command", "⇧": "Shift", "⌫": "Delete", "⎋": "Escape",
        "␣": "Space", "↩": "Return", "↑": "Up Arrow", "↓": "Down Arrow",
        "/": "Slash",
    ]

    private static func spokenLabel(for keys: String) -> String {
        keys.map { key in
            key == " " ? "or" : (Self.spokenKeys[key] ?? String(key))
        }
        .joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(captureHint + " — from any app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // One grid across every group: the keycap column takes one
                // global width, so action labels align down the whole panel
                // instead of waving per group.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                    ForEach(Self.groups, id: \.title) { group in
                        GridRow {
                            Text(group.title)
                                .font(.caption.smallCaps().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .gridCellColumns(2)
                                .padding(.top, 10)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.entries, id: \.keys) { entry in
                            GridRow {
                                // Every key is its own fixed-size cap —
                                // chords are runs of caps, alternatives
                                // ("↑ ↓") get a wider gap — so cap sizes
                                // are uniform everywhere.
                                HStack(spacing: 8) {
                                    ForEach(
                                        Array(entry.keys.split(separator: " ").enumerated()),
                                        id: \.offset
                                    ) { _, chord in
                                        HStack(spacing: 3) {
                                            ForEach(Array(chord.enumerated()), id: \.offset) { _, key in
                                                Text(String(key))
                                                    .font(.callout.monospaced())
                                                    .frame(width: 26, height: 24)
                                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                            }
                                        }
                                    }
                                }
                                // The caps collapse into one spoken element
                                // (the action label stays its own): VoiceOver
                                // would otherwise announce each cap by
                                // Unicode name ("place of interest sign"
                                // for ⌘). The text trait gives the collapsed
                                // element a role; roleless elements expose as
                                // AXUnknown, which VoiceOver reads as empty.
                                .accessibilityElement(children: .ignore)
                                .accessibilityAddTraits(.isStaticText)
                                .accessibilityLabel(Self.spokenLabel(for: entry.keys))
                                Text(entry.action)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Text("Esc or ⌘/ closes this guide.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Escape or \(Self.spokenLabel(for: "⌘/")) closes this guide.")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        // Contain, then label: without an explicit container element the
        // label can propagate onto the content and mask its text; the
        // label keeps VoiceOver from announcing a bare "scroll area". No
        // modal trait — on the container it blocks VoiceOver from
        // interacting with the content; the panel hides its own content
        // while the guide is up instead.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }
}
