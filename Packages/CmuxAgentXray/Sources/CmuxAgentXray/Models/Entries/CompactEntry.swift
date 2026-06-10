public import Foundation

/// Compact-summary entry — JSONL `type: "summary"`. Body holds the
/// summary text in a single `.text` section.
public struct CompactEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let header: Header
    public let body: Body
    /// Abandoned-branch rewinds whose divergence point is this entry.
    /// See ``Entry/branches``.
    public internal(set) var branches: [SynthesizedEntry]

    public init(
        id: EntryID,
        header: Header,
        body: Body,
        branches: [SynthesizedEntry] = []
    ) {
        self.id = id
        self.header = header
        self.body = body
        self.branches = branches
    }

    public var timestamp: Date? { header.timeMarker?.clockDate }
}
