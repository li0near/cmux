import Foundation

/// Raw Claude Code session JSONL line. Each
/// `~/.claude/projects/<dir>/<session>.jsonl` file contains one of these
/// per line.
///
/// We decode only the fields needed to classify, route, and render;
/// unknown fields are ignored by Swift's default Decodable.
///
/// Type universe surveyed across a 523-session corpus:
///   - Tree-affiliated (have `parentUuid`): `user`, `assistant`, `system`,
///     `attachment`, `progress`.
///   - Session-orphan (no `parentUuid`): `last-prompt`, `permission-mode`,
///     `file-history-snapshot`, `agent-name`, `custom-title`, `pr-link`,
///     `queue-operation`.
///
/// `system` lines carry a `subtype`: `turn_duration`, `stop_hook_summary`,
/// `api_error`, `away_summary` (recap), `local_command`, `compact_boundary`,
/// `informational`.
struct ClaudeJSONLLine: Decodable {
    let type: String
    let timestamp: Date?
    let uuid: String?
    let parentUuid: String?
    let promptId: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    /// User and assistant entries carry a `message` field. System/summary
    /// entries do not.
    let message: ClaudeMessage?
    /// Compact-summary marker (older `/compact`-style flow). The newer
    /// flow emits a `system` line with `subtype: compact_boundary` instead.
    let isCompactSummary: Bool?
    /// Top-level `summary` text on legacy summary entries.
    let summary: String?

    /// On `system` entries: drives renderable-vs-skip routing.
    let subtype: String?
    /// `system.subtype: turn_duration` — aggregate duration for the whole
    /// turn (user prompt → final assistant response). Distinct from
    /// per-tool durations, computed from message timestamps.
    let durationMs: Int?
    /// `system.subtype: turn_duration` — message count for the turn.
    let messageCount: Int?
    /// Renderable system body content (errors, hook summaries, recap
    /// bodies, command output).
    let content: String?

    /// `type: last-prompt` — UUID of the active leaf in the rewind tree.
    /// Walk `parentUuid` from this back to the root for the active branch.
    let leafUuid: String?
    /// Verbatim text of the prompt at the active leaf (preview only).
    let lastPrompt: String?

    /// `type: pr-link` payload.
    let prNumber: Int?
    let prUrl: String?
    let prRepository: String?

    /// Session-level metadata (skipped from rendering).
    let agentName: String?
    let customTitle: String?

    /// Sidechain / sub-agent wiring.
    let parentToolUseID: String?

    /// Newer `compact_boundary` flow.
    let compactMetadata: ClaudeCompactMetadata?
    /// `compact_boundary` lines have `parentUuid: null` (they break the
    /// tree) but carry `logicalParentUuid` pointing back at the
    /// pre-compaction tail so branch-walks can stitch the active chain
    /// across the compact event. Empirically observed only on
    /// `system, subtype: compact_boundary` lines, but decoded
    /// unconditionally — future Claude Code versions may use it elsewhere.
    let logicalParentUuid: String?

    /// `type: attachment` — only `queued_command`, `plan_mode` family,
    /// and `edited_text_file` subtypes are user-visible.
    let attachment: ClaudeAttachment?

    /// `type: queue-operation` — `enqueue` / `remove` / `dequeue`. No
    /// uuid/parentUuid; pairs with later `attachment.queued_command`
    /// lines for consumed-state tracking.
    let operation: String?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, uuid, parentUuid, promptId
        case isSidechain, isMeta, message, isCompactSummary, summary
        case subtype, durationMs, messageCount, content
        case leafUuid, lastPrompt
        case prNumber, prUrl, prRepository
        case agentName, customTitle
        case parentToolUseID
        case compactMetadata, logicalParentUuid
        case attachment, operation
    }

    /// Stable id even when `uuid` is absent.
    var stableId: String { uuid ?? UUID().uuidString }

    /// Memberwise init with sensible defaults — synthetic test fixtures
    /// can construct lines without naming every new field. Decodable
    /// synthesis still works for raw JSONL parsing.
    init(
        type: String,
        timestamp: Date? = nil,
        uuid: String? = nil,
        parentUuid: String? = nil,
        promptId: String? = nil,
        isSidechain: Bool? = nil,
        isMeta: Bool? = nil,
        message: ClaudeMessage? = nil,
        isCompactSummary: Bool? = nil,
        summary: String? = nil,
        subtype: String? = nil,
        durationMs: Int? = nil,
        messageCount: Int? = nil,
        content: String? = nil,
        leafUuid: String? = nil,
        lastPrompt: String? = nil,
        prNumber: Int? = nil,
        prUrl: String? = nil,
        prRepository: String? = nil,
        agentName: String? = nil,
        customTitle: String? = nil,
        parentToolUseID: String? = nil,
        compactMetadata: ClaudeCompactMetadata? = nil,
        logicalParentUuid: String? = nil,
        attachment: ClaudeAttachment? = nil,
        operation: String? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.promptId = promptId
        self.isSidechain = isSidechain
        self.isMeta = isMeta
        self.message = message
        self.isCompactSummary = isCompactSummary
        self.summary = summary
        self.subtype = subtype
        self.durationMs = durationMs
        self.messageCount = messageCount
        self.content = content
        self.leafUuid = leafUuid
        self.lastPrompt = lastPrompt
        self.prNumber = prNumber
        self.prUrl = prUrl
        self.prRepository = prRepository
        self.agentName = agentName
        self.customTitle = customTitle
        self.parentToolUseID = parentToolUseID
        self.compactMetadata = compactMetadata
        self.logicalParentUuid = logicalParentUuid
        self.attachment = attachment
        self.operation = operation
    }

    /// True when this line is the active-leaf marker emitted on prompt
    /// submission and on every rewind. The latest such marker in file
    /// order is the current active leaf.
    var isLastPromptMarker: Bool { type == "last-prompt" }

    /// True when this line is session-global metadata with no
    /// `parentUuid` and no renderable body.
    var isSessionOrphanMetadata: Bool {
        switch type {
        case "permission-mode",
             "file-history-snapshot",
             "agent-name",
             "custom-title",
             "queue-operation":
            return true
        default:
            return false
        }
    }

    /// Render-shape body for `isMeta`-flavored user lines and other
    /// special-kind emit paths. Reads `line.content` when present and
    /// non-empty; falls back to the first text block of
    /// `message.content`. Used as the input to wrapper-tag extraction
    /// (e.g. ``ClaudeContentDetector/classify(_:)``) when a line's
    /// renderable text isn't already available.
    var metaBody: String {
        if let body = content, !body.isEmpty { return body }
        return message?.content?.firstText() ?? ""
    }
}
