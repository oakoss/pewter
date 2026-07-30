import Foundation

/// Formats items for the pasteboard.
public enum ItemFormatter {
    /// A single item's raw text, ready to paste into a chat box.
    public static func itemText(_ item: Item) -> String {
        item.text
    }

    /// The given items as a markdown task list (no metadata comments).
    public static func listText(_ items: [Item]) -> String {
        items.map { item in
            let checkbox = item.done ? "- [x]" : "- [ ]"
            let lines = item.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let first = lines.first else { return checkbox }
            // Blank interior lines carry no indentation, matching the file
            // serializer — trailing whitespace gets stripped by editors.
            let continuations = lines.dropFirst().map { $0.isEmpty ? "" : "  \($0)" }
            return ([checkbox + " " + first] + continuations).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}
