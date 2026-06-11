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

    /// Claude-Code-specific side-channel envelope on `tool_result` lines.
    /// Polymorphic across tools — object for Edit / MultiEdit / Write
    /// (carrying ``ClaudeToolUseResult``-shape fields including
    /// `structuredPatch`), bare string for Bash errors, JSON array for
    /// Playwright-style text-block results, distinct object shape for
    /// Task / sub-agent metadata. Decoded as the loose
    /// ``ClaudeJSONValue`` to avoid `typeMismatch` failing the whole
    /// line on the non-object cases; consumers that want the typed
    /// envelope project via ``ClaudeToolUseResult/from(_:)``.
    let toolUseResult: ClaudeJSONValue?

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
        case toolUseResult
    }

    /// Stable id even when `uuid` is absent. Deterministic across
    /// repeated accesses for the same line — for uuid-less lines
    /// (`queue-operation`, `last-prompt`, session-orphan metadata)
    /// the id is synthesized from `type` + `timestamp` + `parentUuid` +
    /// `String.hashValue` of the content. `String.hashValue` is
    /// process-deterministic (same seed for the process lifetime),
    /// which is sufficient — the index keys generated from `stableId`
    /// only need to agree within one `transcript()` rebuild. Without
    /// this determinism, two accesses on the same nil-uuid line yield
    /// two different fresh UUIDs, causing the index alias key to
    /// disagree with the appended entry's id.
    var stableId: String {
        if let uuid { return uuid }
        var key = "synthetic:\(type)"
        if let ts = timestamp {
            key += ":\(ts.timeIntervalSince1970)"
        }
        if let pu = parentUuid, !pu.isEmpty {
            key += ":\(pu)"
        }
        if let c = content, !c.isEmpty {
            key += ":\(c.hashValue)"
        }
        return key
    }

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
        operation: String? = nil,
        toolUseResult: ClaudeJSONValue? = nil
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
        self.toolUseResult = toolUseResult
    }

    /// True when this line is the active-leaf marker emitted on prompt
    /// submission and on every rewind. The latest such marker in file
    /// order is the current active leaf.
    var isLastPromptMarker: Bool { type == "last-prompt" }

    /// Reconstructed `/cmd args` form of a slash-command user line, or
    /// nil if this line is not a slash-command-shaped user line. Used
    /// by the inline FIFO queued-prompt matcher to pair consumed
    /// slash-commands against earlier `queue-operation enqueue` lines.
    var consumedSlashCommandText: String? {
        let raw = message?.content?.firstText() ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<command-message>") || trimmed.hasPrefix("<command-name>") else {
            return nil
        }
        guard case let .slashCommandInput(name, args) = ClaudeContentDetector.classify(trimmed) else {
            return nil
        }
        let slashName = name.hasPrefix("/") ? name : "/\(name)"
        if let args, !args.isEmpty {
            return "\(slashName) \(args)"
        }
        return slashName
    }

    /// True when this line is session-global metadata with no
    /// `parentUuid` and no renderable body.
    ///
    /// `queue-operation` is **not** in this set —
    /// `CommonLineDispatcher` routes `enqueue` operations to
    /// `.queueOperation(text:)` so the builder can append a
    /// `.pending` UserEntry inline.
    var isSessionOrphanMetadata: Bool {
        switch type {
        case "permission-mode",
             "file-history-snapshot",
             "agent-name",
             "custom-title":
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
