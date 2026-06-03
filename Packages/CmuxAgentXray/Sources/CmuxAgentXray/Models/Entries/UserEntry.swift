public import Foundation

/// User-authored prompt entry. Body is normally a single `.text` section
/// holding the prompt body; an empty body means the prompt was suppressed
/// (e.g., a queue marker with no visible content).
public struct UserEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body

    /// Claude's `promptId` field when present on the JSONL line. Used by
    /// `pairClaudeAnchorsToUserChunks` for exact turn-anchor pairing.
    public let promptId: String?
    /// True when this entry was reconstructed from an
    /// `attachment.queued_command` (user typed mid-AI-turn) or paired
    /// against a `queue-operation enqueue` slash command.
    public let wasQueued: Bool
    /// True only while the queued prompt is *pending* (no matching
    /// consumed entry yet). Drives the icon's pulse animation.
    public let isQueuedPending: Bool

    public init(
        id: EntryID,
        timestamp: Date?,
        header: Header,
        body: Body,
        promptId: String? = nil,
        wasQueued: Bool = false,
        isQueuedPending: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.header = header
        self.body = body
        self.promptId = promptId
        self.wasQueued = wasQueued
        self.isQueuedPending = isQueuedPending
    }
}
