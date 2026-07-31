import Foundation

/// Formats items for the pasteboard.
public enum ItemFormatter {
    /// The items' raw text separated by blank lines, so pasted notes stay
    /// distinguishable without list markup — ready for a chat box.
    public static func itemsText(_ items: [Item]) -> String {
        items.map(\.text).joined(separator: "\n\n")
    }

    /// Copy as List output shape. Numbered matches Copper; the other two are
    /// for pasting into markdown documents.
    public enum ListStyle: String, CaseIterable, Sendable {
        case numbered, bulleted, taskList
    }

    /// The given items as a list in the requested style. Checkbox metadata
    /// stays in the notes file; only `taskList` carries done state.
    public static func listText(_ items: [Item], style: ListStyle) -> String {
        items.enumerated().map { index, item in
            let marker = switch style {
            case .numbered: "\(index + 1). "
            case .bulleted: "- "
            case .taskList: item.done ? "- [x] " : "- [ ] "
            }
            // Numbered continuations align under the text (the marker widens
            // past 9); the dash styles use markdown's two-space rule, where
            // brackets are content, not marker. Blank interior lines stay
            // empty so no line carries trailing whitespace.
            let indent = style == .numbered ? String(repeating: " ", count: marker.count) : "  "
            let lines = item.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let first = lines.first else { return String(marker.dropLast()) }
            let continuations = lines.dropFirst().map { $0.isEmpty ? "" : indent + $0 }
            return ([marker + first] + continuations).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}
