import Foundation

/// Value-typed payload describing a Claude prompt-submission event
/// observed by the cmux app's v1 socket router. Posted as
/// `Notification.Name.cmuxClaudePromptSubmitted` userInfo so the
/// `AgentInspectorPanel` can record an *exact* turn anchor for the
/// surface, paired against the user-chunk that's about to land in the
/// JSONL transcript.
///
/// The fields are split into two groups:
///
/// - **Invariants**: `sessionId`, `turnId`, `transcriptPath`,
///   `transcriptBytes`, `capturedAt`. Once captured, these never
///   change; they identify the turn across the JSONL on disk.
/// - **Per-surface dynamic state**: `surfaceId`, `terminalRowAtSubmit`,
///   `totalAtCapture`. Meaningful only within the lifetime of one
///   Ghostty surface; stored alongside `totalAtCapture` so the
///   inspector can scale the row on terminal resize.
struct ClaudeAnchorPayload: Equatable, Sendable {
    /// Claude session UUID. Matches `ResolvedAgentSession.sessionId`.
    let sessionId: String
    /// Surface UUID (= `CMUX_SURFACE_ID` = `TerminalSurface.id`).
    let surfaceId: UUID
    /// Claude turn id from the `prompt-submit` hook stdin payload.
    let turnId: String
    /// JSONL transcript path on disk.
    let transcriptPath: String
    /// Byte length of `transcriptPath` at the moment the hook fired.
    /// The corresponding user-chunk lands at offset >= this byte; used
    /// for FIFO matching when a chunk arrives in the inspector's
    /// stream.
    let transcriptBytes: UInt64
    /// `scrollbar.total` of `surfaceId` at the moment the v1 router
    /// received the `claude_anchor` command — i.e. the row index just
    /// past the last existing scrollback line at submit time. The
    /// prompt's first row sits at `terminalRowAtSubmit` (claude
    /// renders the prompt at the bottom of scrollback, so the box
    /// occupies the next few rows from this anchor downward).
    let terminalRowAtSubmit: UInt64
    /// `scrollbar.total` snapshot at capture time. Stored alongside
    /// `terminalRowAtSubmit` so the inspector can scale the row on
    /// terminal resize:
    /// `effectiveRow = terminalRowAtSubmit × currentTotal / totalAtCapture`.
    let totalAtCapture: UInt64
    /// Wall-clock timestamp of capture. Useful for debug logs and
    /// stale-cache races.
    let capturedAt: Date
}

extension Notification {
    /// Read a `ClaudeAnchorPayload` from the `userInfo` of a
    /// `cmuxClaudePromptSubmitted` notification.
    static let claudeAnchorPayloadKey = "cmuxClaudeAnchorPayload"

    var claudeAnchorPayload: ClaudeAnchorPayload? {
        userInfo?[Notification.claudeAnchorPayloadKey] as? ClaudeAnchorPayload
    }
}
