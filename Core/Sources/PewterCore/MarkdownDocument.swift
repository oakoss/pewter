import CryptoKit
import Foundation

/// A single line of the notes file: a task item, a `## ` section heading, or
/// a line we don't interpret (blanks, prose, other heading levels) preserved
/// verbatim on round-trip.
public enum MarkdownLine: Equatable, Sendable {
    case item(Item)
    case heading(SectionHeading)
    case verbatim(String)
}

/// A `## ` section heading line. `raw` keeps the exact bytes for round-trip;
/// `title` is the trimmed text. The id lets views track a section across
/// renders and is never written to the file; it's derived from `raw` at
/// classification time, so reloading an unchanged file keeps identity
/// stable. Equality compares `raw` alone — a standalone value can't know
/// the occurrence index its id encodes, and content is what document
/// comparison needs.
public struct SectionHeading: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let raw: String
    public let title: String

    init(id: UUID = UUID(), raw: String, title: String) {
        self.id = id
        self.raw = raw
        self.title = title
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.raw == rhs.raw
    }
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
        // multiple lines and break round-trip; split it up front. Classifying
        // headings here, the single choke point every line passes through,
        // keeps `.verbatim("## X")` and `.heading` from coexisting as two
        // unequal spellings of the same file line.
        var occurrences: [String: Int] = [:]
        self.lines = lines.flatMap { line -> [MarkdownLine] in
            guard case let .verbatim(text) = line, text.contains(where: \.isNewline) else { return [line] }
            return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { .verbatim(String($0)) }
        }
        .map { line in
            guard case let .verbatim(text) = line,
                  let match = text.wholeMatch(of: Self.sectionHeading) else { return line }
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return .heading(SectionHeading(
                id: Self.headingID(raw: text, occurrence: occurrence),
                raw: text,
                title: String(match.title)
            ))
        }
    }

    /// Deterministic: an external reload re-parses the whole file, and a
    /// random id would tear down and rebuild every section's rows — losing
    /// row state like in-progress edits. The occurrence index keeps duplicate
    /// headings distinct.
    private static func headingID(raw: String, occurrence: Int) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(occurrence)\n\(raw)".utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public var items: [Item] {
        lines.compactMap {
            if case let .item(item) = $0 {
                return item
            }
            return nil
        }
    }

    /// A heading and the items grouped beneath it. `heading` is nil for items
    /// above the first heading; non-nil headings are non-empty with
    /// surrounding spaces stripped. Items may be a filtered subset of what's
    /// actually under the heading in the document. The id comes from the
    /// heading line, so it stays stable while other sections appear or
    /// disappear — with one exception: duplicate headings are told apart by
    /// position, so removing or inserting an earlier duplicate shifts the
    /// later ones' identity.
    public struct Section: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let heading: String?
        public let items: [Item]
    }

    /// The preamble has no heading line to borrow identity from; at most one
    /// exists per document, so a fixed id is safe.
    private static let preambleSectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Items grouped by `## ` heading lines. A heading with no items yields
    /// an empty section — it's real structure the user put in the file. Only
    /// level-2 headings group; `#` and `###`+ lines stay plain verbatim, so
    /// prose documents with a title don't sprout accidental sections.
    public var sections: [Section] {
        var sections: [Section] = []
        var current: SectionHeading?
        var pending: [Item] = []

        func flush() {
            if let current {
                sections.append(Section(id: current.id, heading: current.title, items: pending))
            } else if !pending.isEmpty {
                sections.append(Section(id: Self.preambleSectionID, heading: nil, items: pending))
            }
            pending = []
        }

        for line in lines {
            switch line {
            case let .item(item):
                pending.append(item)
            case let .heading(heading):
                flush()
                current = heading
            case .verbatim:
                break
            }
        }
        flush()
        return sections
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

    public mutating func setDone(ids: Set<UUID>, done: Bool) {
        for index in lines.indices {
            guard case var .item(item) = lines[index], ids.contains(item.id), item.done != done else { continue }
            item.done = done
            lines[index] = .item(item)
        }
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
    // The title must start with a non-space, or backtracking lets `## ` plus
    // trailing spaces match as a blank-titled heading.
    private nonisolated(unsafe) static let sectionHeading = /^## +(?<title>\S.*?) *$/

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
            case let .heading(heading):
                output.append(heading.raw)
            case let .item(item):
                output.append(Self.serialize(item))
            }
        }
        return output.joined(separator: "\n") + (output.isEmpty ? "" : "\n")
    }

    private static func serialize(_ item: Item) -> String {
        let meta = "<!--sl id=\(item.id.uuidString.lowercased()) created=\(formatDate(item.createdAt))-->"
        return ItemFormatter.entry(
            marker: ItemFormatter.taskMarker(done: item.done),
            text: item.text,
            indent: "  ",
            firstLineSuffix: " " + meta
        )
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parseDate(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}
