import Foundation

/// A single line of the notes file: either a task item or a line we don't
/// interpret (headings, blanks, prose) preserved verbatim on round-trip.
public enum MarkdownLine: Equatable, Sendable {
    case item(Item)
    case verbatim(String)
}

/// Parses and serializes the notes file.
///
/// Format: GitHub task-list lines with an invisible HTML-comment metadata
/// suffix. Item text may span multiple lines; continuation lines are indented
/// two spaces, and blank interior lines carry no indentation (external
/// editors strip trailing whitespace):
///
///     - [ ] Ask Claude about retry logic <!--sl id=... created=...-->
///       second line of the same item
///
/// Task lines without the metadata comment (hand-added in an editor) are
/// adopted with a fresh id and timestamp.
public struct MarkdownDocument: Equatable, Sendable {
    public private(set) var lines: [MarkdownLine]

    public init(lines: [MarkdownLine] = []) {
        // A verbatim entry with embedded line breaks would serialize to
        // multiple lines and break round-trip; split it up front.
        self.lines = lines.flatMap { line -> [MarkdownLine] in
            guard case let .verbatim(text) = line, text.contains(where: \.isNewline) else { return [line] }
            return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { .verbatim(String($0)) }
        }
    }

    public var items: [Item] {
        lines.compactMap {
            if case let .item(item) = $0 {
                return item
            }
            return nil
        }
    }

    // MARK: - Mutations

    public mutating func append(_ item: Item) {
        lines.append(.item(item))
    }

    @discardableResult
    public mutating func update(_ item: Item) -> Bool {
        guard let index = index(of: item.id) else { return false }
        lines[index] = .item(item)
        return true
    }

    /// An item removed by `removeAll`, with its pre-removal index in `lines`.
    public struct RemovedItem: Equatable, Sendable {
        public let index: Int
        public let item: Item
    }

    /// - Precondition: `0 <= index <= lines.count` — traps like
    ///   `Array.insert`.
    public mutating func insert(_ item: Item, at index: Int) {
        lines.insert(.item(item), at: index)
    }

    /// Returns removed items in ascending index order — the shape undo needs
    /// to re-insert them.
    public mutating func removeAll(ids: Set<UUID>) -> [RemovedItem] {
        var removed: [RemovedItem] = []
        var kept: [MarkdownLine] = []
        for (index, line) in lines.enumerated() {
            if case let .item(item) = line, ids.contains(item.id) {
                removed.append(RemovedItem(index: index, item: item))
            } else {
                kept.append(line)
            }
        }
        lines = kept
        return removed
    }

    @discardableResult
    public mutating func setDone(ids: Set<UUID>, done: Bool) -> Bool {
        var changed = false
        for index in lines.indices {
            guard case var .item(item) = lines[index], ids.contains(item.id), item.done != done else { continue }
            item.done = done
            lines[index] = .item(item)
            changed = true
        }
        return changed
    }

    private func index(of id: UUID) -> Int? {
        lines.firstIndex {
            if case let .item(item) = $0 {
                return item.id == id
            }
            return false
        }
    }

    // MARK: - Parsing

    // Immutable after creation, so sharing across threads is safe despite
    // Regex not being Sendable.
    private nonisolated(unsafe) static let taskLine = /^- \[(?<done>[ xX])\] (?<rest>.*)$/
    private nonisolated(unsafe) static let metadata =
        /\s*<!--sl id=(?<id>[0-9a-fA-F-]{36}) created=(?<created>[^>]+?)-->\s*$/

    public static func parse(_ text: String, now: Date = .now) -> MarkdownDocument {
        var lines: [MarkdownLine] = []
        var pendingItem: Item?
        var pendingRawLines: [String] = []
        var pendingBlanks: [String] = []
        var seenIDs = Set<UUID>()

        func flush() {
            defer {
                pendingItem = nil
                pendingRawLines = []
                // Blank lines that never got a continuation after them belong
                // to the document, not the item.
                lines.append(contentsOf: pendingBlanks.map { .verbatim($0) })
                pendingBlanks = []
            }
            guard var item = pendingItem else { return }

            item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.text.isEmpty else {
                // An empty task line isn't a usable item; keep its bytes.
                lines.append(contentsOf: pendingRawLines.map { .verbatim($0) })
                return
            }

            // A hand-duplicated line carries a duplicate id; adopt the copy
            // with a fresh identity, same as a metadata-less line.
            if seenIDs.contains(item.id) {
                item = Item(text: item.text, done: item.done, createdAt: now)
            }
            seenIDs.insert(item.id)
            lines.append(.item(item))
        }

        // Splitting on Character boundaries treats "\r\n" as one newline, so
        // CRLF files parse too; serialization normalizes to LF.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)

            if let match = line.wholeMatch(of: taskLine) {
                flush()
                pendingItem = parseItem(
                    done: match.done != " ",
                    rest: String(match.rest),
                    now: now
                )
                pendingRawLines = [line]
            } else if pendingItem != nil, line.hasPrefix("  ") {
                // Blank lines between continuations are interior to the item.
                for blank in pendingBlanks {
                    pendingItem?.text += "\n"
                    pendingRawLines.append(blank)
                }
                pendingBlanks = []
                pendingItem?.text += "\n" + line.dropFirst(2)
                pendingRawLines.append(line)
            } else if pendingItem != nil, line.isEmpty {
                // Might be an interior blank of a multi-line item or a
                // document-level separator; decided by what follows.
                pendingBlanks.append(line)
            } else {
                flush()
                lines.append(.verbatim(line))
            }
        }
        flush()

        // A trailing newline in the source produces one empty verbatim line;
        // drop it so parse/serialize round-trips exactly.
        if case .verbatim("") = lines.last {
            lines.removeLast()
        }

        return MarkdownDocument(lines: lines)
    }

    private static func parseItem(done: Bool, rest: String, now: Date) -> Item {
        var text = rest
        var id = UUID()
        var createdAt = now

        if let match = rest.firstMatch(of: metadata) {
            if let parsedID = UUID(uuidString: String(match.id)) {
                id = parsedID
                createdAt = parseDate(String(match.created)) ?? now
            }
            text = String(rest[..<match.range.lowerBound])
        }

        return Item(
            id: id,
            text: text.trimmingCharacters(in: .whitespaces),
            done: done,
            createdAt: createdAt
        )
    }

    // MARK: - Serialization

    public func serialized() -> String {
        var output: [String] = []
        for line in lines {
            switch line {
            case let .verbatim(text):
                output.append(text)
            case let .item(item):
                output.append(Self.serialize(item))
            }
        }
        return output.joined(separator: "\n") + (output.isEmpty ? "" : "\n")
    }

    private static func serialize(_ item: Item) -> String {
        let checkbox = item.done ? "- [x]" : "- [ ]"
        let meta = "<!--sl id=\(item.id.uuidString.lowercased()) created=\(formatDate(item.createdAt))-->"

        var textLines = item.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = textLines.isEmpty ? "" : textLines.removeFirst()

        var result = "\(checkbox) \(first) \(meta)"
        for continuation in textLines {
            // Blank interior lines serialize with no indentation — trailing
            // whitespace would be stripped by most external editors, which
            // used to fragment the item on reload.
            result += continuation.isEmpty ? "\n" : "\n  " + continuation
        }
        return result
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parseDate(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}
