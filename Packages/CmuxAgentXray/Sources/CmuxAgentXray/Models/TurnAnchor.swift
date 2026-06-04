public import Foundation

/// Per-turn anchor record used by the panel's scroll-sync.
///
/// One anchor pairs a user prompt entry with the paired terminal's
/// scrollback row count at submission time. The "end" of a turn is
/// implicit — it's the next anchor's `terminalRowAtSubmit` (or the live
/// `total` if this is the latest turn). That's enough for the
/// proportional within-turn mapping the panel uses.
///
/// Pure value type. The mutable session-scoped store that owns
/// `[String: TurnAnchor]` lives in the Behavior layer.
public struct TurnAnchor: Identifiable, Equatable, Sendable {
    /// User-prompt entry id (turn start) — matches `UserEntry.id`.
    /// `Identifiable` conformance points at this so the store can use
    /// `[TurnAnchor]` projections directly in SwiftUI.
    public let userEntryID: String
    /// Agent turn id paired with this user prompt. Nil while the
    /// assistant response hasn't started streaming yet. Updated once
    /// the trailing `AgentEntry` first becomes visible in the stream.
    public var agentEntryID: String?
    /// Terminal `total` scrollback rows at user-prompt observation
    /// time. Read from the host's scrollbar snapshot at the moment the
    /// user entry first appears in the stream, OR delivered exactly via
    /// the `claude_anchor` socket command when the panel + cmux are
    /// running together.
    public let terminalRowAtSubmit: UInt64
    /// `scrollbar.total` snapshot at capture time. Used by the
    /// visibility filter to scale `terminalRowAtSubmit` on terminal
    /// resize / rewrap. `0` means "treat as unscaled" (used for
    /// synthetic / test-only anchors).
    public let totalAtCapture: UInt64
    /// Wall-clock at which the anchor was captured. Useful for
    /// debugging stale-cache races.
    public let capturedAt: Date

    public var id: String { userEntryID }

    public init(
        userEntryID: String,
        agentEntryID: String? = nil,
        terminalRowAtSubmit: UInt64,
        totalAtCapture: UInt64,
        capturedAt: Date
    ) {
        self.userEntryID = userEntryID
        self.agentEntryID = agentEntryID
        self.terminalRowAtSubmit = terminalRowAtSubmit
        self.totalAtCapture = totalAtCapture
        self.capturedAt = capturedAt
    }
}
