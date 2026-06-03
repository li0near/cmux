public import Foundation

/// Compact-summary entry — JSONL `type: "summary"`. Body holds the
/// summary text in a single `.text` section.
public struct CompactEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body

    public init(
        id: EntryID,
        timestamp: Date?,
        header: Header,
        body: Body
    ) {
        self.id = id
        self.timestamp = timestamp
        self.header = header
        self.body = body
    }
}
