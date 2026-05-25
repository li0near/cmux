import Foundation

/// Raw Claude Code session JSONL line. Each `~/.claude/projects/<dir>/<session>.jsonl`
/// file contains one of these per line.
///
/// Schema borrows ideas from `claude-devtools/src/main/types/jsonl.ts`. We decode
/// only the fields we need to classify, route, and render; unknown fields are
/// ignored by Swift's default Decodable.
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
    let isSidechain: Bool?
    let isMeta: Bool?
    /// User and assistant entries carry a `message` field. System/summary
    /// entries do not, so this is optional.
    let message: ClaudeMessage?
    /// Compact-summary marker (older `/compact`-style flow) — when true the
    /// user line carries a synthesized compaction summary. The newer flow
    /// emits a `system` line with `subtype: compact_boundary` instead.
    let isCompactSummary: Bool?
    /// Top-level `summary` text on legacy summary entries.
    let summary: String?

    // MARK: - System subtype + per-turn timing
    /// On `system` entries (`turn_duration`, `away_summary`, `compact_boundary`,
    /// etc). Drives renderable-vs-skip routing for system lines.
    let subtype: String?
    /// `system.subtype: turn_duration` carries this aggregate duration for the
    /// whole turn (user prompt → final assistant response). Distinct from
    /// per-tool durations, which we still compute from message timestamps.
    let durationMs: Int?
    /// `system.subtype: turn_duration` companion: how many messages the turn
    /// contained.
    let messageCount: Int?
    /// `system` lines representing renderable content (errors, hook summaries,
    /// recap bodies, command output) carry the body here. Distinct from the
    /// `message` envelope used by user/assistant lines.
    let content: String?

    // MARK: - Rewind tree marker (`type: last-prompt`)
    /// UUID of the current active leaf in the rewind tree. Walk `parentUuid`
    /// from this back to the root to derive the active branch.
    let leafUuid: String?
    /// Verbatim text of the prompt at the active leaf (preview only).
    let lastPrompt: String?

    // MARK: - PR link (`type: pr-link`)
    let prNumber: Int?
    let prUrl: String?
    let prRepository: String?

    // MARK: - Session-level metadata (skipped from rendering)
    let agentName: String?
    let customTitle: String?

    // MARK: - Sub-agent / sidechain wiring
    /// On sidechain lines (`isSidechain: true`) and `progress` lines, ties the
    /// line back to its parent agent's `Task`/`Agent` tool-use id.
    let parentToolUseID: String?
    /// On tool-related lines, the `tool_use` id this line corresponds to.
    let toolUseID: String?

    // MARK: - Compact metadata (newer compact_boundary flow)
    let compactMetadata: ClaudeCompactMetadata?

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case uuid
        case parentUuid
        case isSidechain
        case isMeta
        case message
        case isCompactSummary
        case summary
        case subtype
        case durationMs
        case messageCount
        case content
        case leafUuid
        case lastPrompt
        case prNumber
        case prUrl
        case prRepository
        case agentName
        case customTitle
        case parentToolUseID
        case toolUseID
        case compactMetadata
    }

    /// Convenience for callers that want a stable id even when uuid is absent.
    var stableId: String {
        uuid ?? UUID().uuidString
    }

    /// Memberwise init with sensible defaults for all newly-added fields,
    /// so synthetic test fixtures that construct lines directly continue
    /// to compile without naming every new field. Decodable synthesis still
    /// works for raw JSONL parsing.
    init(
        type: String,
        timestamp: Date? = nil,
        uuid: String? = nil,
        parentUuid: String? = nil,
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
        compactMetadata: ClaudeCompactMetadata? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.uuid = uuid
        self.parentUuid = parentUuid
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
    }

    /// True when this line is the active-leaf marker emitted on prompt
    /// submission and on every rewind. The latest such marker in file order
    /// is the current active leaf.
    var isLastPromptMarker: Bool {
        type == "last-prompt"
    }

    /// True when this line is session-global metadata with no `parentUuid`
    /// and no renderable body — it describes the whole session, not any
    /// branch within it.
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

    enum CodingKeys: String, CodingKey {
        case preTokens
        case postTokens
        case durationMs
    }
}

/// `message` body for user / assistant entries.
struct ClaudeMessage: Decodable {
    let role: String?
    let model: String?
    /// `string | ContentBlock[]` in the JSON. We model both with a custom
    /// decoder.
    let content: ClaudeMessageContent?
    let stopReason: String?
    let usage: ClaudeUsage?

    enum CodingKeys: String, CodingKey {
        case role
        case model
        case content
        case stopReason = "stop_reason"
        case usage
    }

    init(
        role: String?,
        model: String?,
        content: ClaudeMessageContent?,
        stopReason: String?,
        usage: ClaudeUsage? = nil
    ) {
        self.role = role
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
            return
        }
        let arr = try container.decode([ClaudeContentBlock].self)
        self = .blocks(arr)
    }
}

/// One element of an array-shaped `message.content`.
struct ClaudeContentBlock: Decodable, Equatable {
    let type: String
    /// `text` block.
    let text: String?
    /// `thinking` block.
    let thinking: String?
    /// `tool_use` block.
    let id: String?
    let name: String?
    let input: ClaudeJSONValue?
    /// `tool_result` block.
    let toolUseId: String?
    let toolResultContent: ClaudeJSONValue?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case id
        case name
        case input
        case toolUseId = "tool_use_id"
        case toolResultContent = "content"
        case isError = "is_error"
    }
}

/// Loosely-typed JSON value for tool input/result payloads. We stringify these
/// when displaying so downstream code never has to deal with the full JSON
/// object model.
indirect enum ClaudeJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ClaudeJSONValue])
    case object([String: ClaudeJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let v = try? container.decode(Bool.self) {
            self = .bool(v); return
        }
        if let v = try? container.decode(Int.self) {
            self = .int(v); return
        }
        if let v = try? container.decode(Double.self) {
            self = .double(v); return
        }
        if let v = try? container.decode(String.self) {
            self = .string(v); return
        }
        if let v = try? container.decode([ClaudeJSONValue].self) {
            self = .array(v); return
        }
        if let v = try? container.decode([String: ClaudeJSONValue].self) {
            self = .object(v); return
        }
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

/// JSON decoder shared across Agent Inspector parsing. ISO-8601 dates with
/// fractional seconds match the Claude/Codex transcript format.
enum AgentInspectorJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = formatter.date(from: s) ?? fallback.date(from: s) {
                return date
            }
            // Some entries store the timestamp as ISO without zone separator;
            // fall back to RFC3339-ish parsing.
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
