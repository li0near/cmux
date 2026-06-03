public import Foundation

/// Value-typed payload describing a Claude prompt-submission event
/// observed by the cmux app's socket router. Posted as the userInfo of
/// `Notification.Name.cmuxClaudePromptSubmitted` so the panel can
/// record an *exact* turn anchor for the surface, paired against the
/// user entry that's about to land in the JSONL transcript.
///
/// Two field groups:
/// - **Invariants**: `sessionID`, `turnID`, `transcriptPath`,
///   `transcriptBytes`, `capturedAt`. Once captured, these never
///   change; they identify the turn across the JSONL on disk.
/// - **Per-surface dynamic state**: `surfaceID`, `terminalRowAtSubmit`,
///   `totalAtCapture`. Meaningful only within the lifetime of one
///   Ghostty surface; stored alongside `totalAtCapture` so the panel
///   can scale the row on terminal resize.
///
/// The pairing algorithm that consumes this payload lives in the
/// Behavior layer (`Behavior/Anchors/AnchorPairing.swift`).
public struct ClaudeAnchorPayload: Equatable, Sendable {
    /// Claude session UUID. Matches `ResolvedAgentSession.sessionID`.
    public let sessionID: String
    /// Surface UUID (= `CMUX_SURFACE_ID` = panel UUID host-side).
    public let surfaceID: UUID
    /// Claude turn id from the `prompt-submit` hook stdin payload when
    /// present. Claude Code 2.1.133 does not expose this on
    /// `UserPromptSubmit`, so prompt-text + future-stream boundaries
    /// are the normal live pairing path.
    public let turnID: String?
    /// JSONL transcript path on disk.
    public let transcriptPath: String
    /// Prompt text from the `UserPromptSubmit` hook input. Used only
    /// to pair this live anchor to a future user entry within the same
    /// session; never to search historical entries.
    public let submittedPromptText: String?
    /// Byte length of `transcriptPath` at the moment the hook fired.
    /// Reserved for byte-offset matching if entries start carrying
    /// source offsets; current pairing uses `turnID` plus the
    /// stream-arrival boundary recorded by `PendingClaudeAnchor`.
    public let transcriptBytes: UInt64
    /// `scrollbar.total` of `surfaceID` at the moment the v1 router
    /// received the `claude_anchor` command — i.e. the row index just
    /// past the last existing scrollback line at submit time.
    public let terminalRowAtSubmit: UInt64
    /// `scrollbar.total` snapshot at capture time. Stored alongside
    /// `terminalRowAtSubmit` so the panel can scale the row on
    /// terminal resize:
    /// `effectiveRow = terminalRowAtSubmit × currentTotal / totalAtCapture`.
    public let totalAtCapture: UInt64
    /// Wall-clock timestamp of capture. Useful for debug logs and
    /// stale-cache races.
    public let capturedAt: Date

    public init(
        sessionID: String,
        surfaceID: UUID,
        turnID: String? = nil,
        transcriptPath: String,
        submittedPromptText: String? = nil,
        transcriptBytes: UInt64,
        terminalRowAtSubmit: UInt64,
        totalAtCapture: UInt64,
        capturedAt: Date
    ) {
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.turnID = turnID
        self.transcriptPath = transcriptPath
        self.submittedPromptText = submittedPromptText
        self.transcriptBytes = transcriptBytes
        self.terminalRowAtSubmit = terminalRowAtSubmit
        self.totalAtCapture = totalAtCapture
        self.capturedAt = capturedAt
    }
}

/// Base64-JSON wire payload for `claude_anchor_v2`. The cmux-app socket
/// handler enriches this with live terminal row state before posting a
/// `ClaudeAnchorPayload` notification.
public struct ClaudeAnchorSocketPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let surfaceID: UUID
    public let turnID: String?
    public let transcriptPath: String
    public let transcriptBytes: UInt64
    public let submittedPromptText: String?

    public init(
        sessionID: String,
        surfaceID: UUID,
        turnID: String?,
        transcriptPath: String,
        transcriptBytes: UInt64,
        submittedPromptText: String?
    ) {
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.turnID = turnID
        self.transcriptPath = transcriptPath
        self.transcriptBytes = transcriptBytes
        self.submittedPromptText = submittedPromptText
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case surfaceID = "surface_id"
        case turnID = "turn_id"
        case transcriptPath = "transcript_path"
        case transcriptBytes = "transcript_bytes"
        case submittedPromptText = "prompt"
    }
}

// MARK: - Notification contract

extension Notification.Name {
    /// Posted by the cmux app's socket router when a Claude
    /// `prompt-submit` hook fires. The userInfo carries a
    /// `ClaudeAnchorPayload` under `Notification.claudeAnchorPayloadKey`.
    /// The panel subscribes to record an exact turn anchor.
    ///
    /// This name is the cross-process contract between the cmux app
    /// (which posts) and the package (which consumes). Both sides
    /// reference this declaration to avoid string drift.
    public static let cmuxClaudePromptSubmitted = Notification.Name(
        "com.cmux.claude.promptSubmitted"
    )
}

extension Notification {
    /// userInfo key for `ClaudeAnchorPayload` on a
    /// `cmuxClaudePromptSubmitted` notification.
    public static let claudeAnchorPayloadKey = "cmuxClaudeAnchorPayload"

    /// Read a `ClaudeAnchorPayload` from a
    /// `cmuxClaudePromptSubmitted` notification's userInfo.
    public var claudeAnchorPayload: ClaudeAnchorPayload? {
        userInfo?[Notification.claudeAnchorPayloadKey] as? ClaudeAnchorPayload
    }
}
