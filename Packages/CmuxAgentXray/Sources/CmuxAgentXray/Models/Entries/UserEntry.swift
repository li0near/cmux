public import Foundation

/// User-authored prompt entry. Body is normally a single `.text` section
/// holding the prompt body; an empty body means the prompt was suppressed
/// (e.g., a queue marker with no visible content).
public struct UserEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let header: Header
    public let body: Body

    /// Claude's `promptId` field when present on the JSONL line. Used by
    /// `pairClaudeAnchorsToUserChunks` for exact turn-anchor pairing.
    public let promptId: String?
    /// Queued-prompt state. Discriminates the three legitimate states a
    /// user prompt can be in: a typed-inline regular prompt (`.none`),
    /// a queued prompt that has settled into the transcript (`.consumed`),
    /// or a tail-pinned synthetic awaiting consumption (`.pending` —
    /// drives the icon's pulse animation).
    public let queuedState: QueuedState

    public init(
        id: EntryID,
        header: Header,
        body: Body,
        promptId: String? = nil,
        queuedState: QueuedState = .none
    ) {
        self.id = id
        self.header = header
        self.body = body
        self.promptId = promptId
        self.queuedState = queuedState
    }

    /// Wall-clock timestamp of this entry, projected from the header's
    /// `timeMarker.clock` payload. Nil when the header has no clock
    /// marker.
    public var timestamp: Date? { header.timeMarker?.clockDate }

    /// Three legitimate states for a user prompt. The earlier shape used
    /// `wasQueued: Bool` + `isQueuedPending: Bool` which permitted a
    /// fourth, impossible combination (`wasQueued: false,
    /// isQueuedPending: true`). The enum encodes the invariant
    /// directly.
    public enum QueuedState: Equatable, Sendable {
        /// Typed-inline regular prompt — no queue involvement.
        case none
        /// Was queued mid-turn and has now settled into the transcript.
        /// Renders with the queued-user icon, no pulse.
        case consumed
        /// Tail-pinned synthetic prompt awaiting a consumer line.
        /// Renders with the queued-user icon plus pulse animation.
        case pending
    }
}
