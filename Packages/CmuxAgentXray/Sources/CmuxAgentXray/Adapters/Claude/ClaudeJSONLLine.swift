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
    let toolUseID: String?

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
        case parentToolUseID, toolUseID
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
        toolUseID: String? = nil,
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
        self.toolUseID = toolUseID
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
}

/// `system.subtype: compact_boundary` companion payload.
struct ClaudeCompactMetadata: Decodable, Equatable {
    let preTokens: Int?
    let postTokens: Int?
    let durationMs: Int?
}

/// `attachment` line payload.
struct ClaudeAttachment: Decodable, Equatable {
    /// Discriminator: `queued_command`, `plan_mode`, `plan_mode_exit`,
    /// `plan_mode_reentry`, `edited_text_file`, `hook_success`,
    /// `task_reminder`, `diagnostics`, `skill_listing`,
    /// `deferred_tools_delta`, `command_permissions`, `date_change`,
    /// `hook_non_blocking_error`.
    let type: String?
    /// `queued_command` — the queued user prompt text.
    let prompt: ClaudeMessageContent?
    /// `edited_text_file` — absolute filename.
    let filename: String?
    /// `edited_text_file` — file content snippet at edit time.
    let snippet: String?
    /// `plan_mode` family — path of the plan file.
    let planFilePath: String?
    /// `plan_mode` family — whether the plan file already exists on disk.
    let planExists: Bool?
    /// `plan_mode` only — `"full"` / `"reentry"` etc.
    let reminderType: String?
    /// `queued_command` only — origin discriminator.
    /// `"prompt"` = user typed mid-AI-turn (render as user message).
    /// `"task-notification"` = harness echo of a background-task
    /// completion (`Bash(run_in_background: true)`); skip.
    /// nil on older sessions; treat as `"prompt"`.
    let commandMode: String?
}

/// `message` body for user / assistant entries.
struct ClaudeMessage: Decodable {
    let id: String?
    let role: String?
    let model: String?
    /// `string | ContentBlock[]` in the JSON.
    let content: ClaudeMessageContent?
    let stopReason: String?
    let usage: ClaudeUsage?

    enum CodingKeys: String, CodingKey {
        case id, role, model, content
        case stopReason = "stop_reason"
        case usage
    }

    init(
        id: String? = nil,
        role: String?,
        model: String?,
        content: ClaudeMessageContent?,
        stopReason: String?,
        usage: ClaudeUsage? = nil
    ) {
        self.id = id
        self.role = role
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.content = try container.decodeIfPresent(ClaudeMessageContent.self, forKey: .content)
        self.stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        self.usage = try container.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
    }
}

/// Token counts reported on assistant messages.
struct ClaudeUsage: Decodable, Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

/// Either a single string or an array of typed content blocks.
enum ClaudeMessageContent: Decodable, Equatable {
    case text(String)
    case blocks([ClaudeContentBlock])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
            return
        }
        let arr = try container.decode([ClaudeContentBlock].self)
        self = .blocks(arr)
    }

    /// String content of this message: the wrapped string for `.text`,
    /// the first text-block's payload for `.blocks` (else empty).
    func firstText() -> String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            for block in blocks where block.type == "text" {
                if let t = block.text { return t }
            }
            return ""
        }
    }
}

/// One element of an array-shaped `message.content`.
struct ClaudeContentBlock: Decodable, Equatable {
    let type: String
    let text: String?
    let thinking: String?
    let id: String?
    let name: String?
    let input: ClaudeJSONValue?
    let toolUseId: String?
    let toolResultContent: ClaudeJSONValue?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseId = "tool_use_id"
        case toolResultContent = "content"
        case isError = "is_error"
    }
}

/// Loosely-typed JSON value for tool input/result payloads. Stringified
/// when displaying so downstream code never has to deal with the full
/// JSON object model.
indirect enum ClaudeJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ClaudeJSONValue])
    case object([String: ClaudeJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([ClaudeJSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: ClaudeJSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognised JSON value"
        )
    }

    /// Best-effort string for tool-call summaries.
    var displayString: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .array(let arr):
            return arr.map(\.displayString).joined(separator: ", ")
        case .object(let obj):
            return obj.map { "\($0.key): \($0.value.displayString)" }
                .sorted()
                .joined(separator: ", ")
        }
    }
}

/// JSON decoder shared across the package's parsing layer. ISO-8601
/// dates with fractional seconds match the Claude/Codex transcript
/// format; falls back to no-fraction and RFC3339-ish parsing.
enum AgentXrayJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            // Formatters created per-call: ISO8601DateFormatter is not
            // Sendable, so we cannot capture instances in this @Sendable
            // closure. Allocation cost is ~µs and the parse path runs
            // off-main, so this is fine.
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: s) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: s) {
                return date
            }
            let rfc = DateFormatter()
            rfc.locale = Locale(identifier: "en_US_POSIX")
            rfc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
            if let date = rfc.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised timestamp: \(s)"
            )
        }
        return d
    }()
}
