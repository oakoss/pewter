import Foundation

public struct Item: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var done: Bool
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, done: Bool = false, createdAt: Date = .now) {
        self.id = id
        // Normalize every Unicode line break (\r\n, \r, U+000B from Word,
        // U+2028 from Cocoa text views, …) to \n at the single ingest choke
        // point — the serializer splits on \n, and any other separator would
        // be written into the middle of a task line and corrupt the file.
        self.text = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.done = done
        self.createdAt = createdAt
    }
}
