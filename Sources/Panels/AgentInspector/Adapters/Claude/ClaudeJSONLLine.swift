import Foundation

/// Raw Claude Code session JSONL line. Each `~/.claude/projects/<dir>/<session>.jsonl`
/// file contains one of these per line.
///
/// Schema mirrors `claude-devtools/src/main/types/jsonl.ts`. We decode only the
/// fields we need to classify and render; unknown fields are ignored by
/// Swift's default Decodable.
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
    /// Compact-summary marker (newer Claude versions) — when true the line is
    /// a CompactChunk.
    let isCompactSummary: Bool?
    /// On `summary` entries.
    let summary: String?

    /// Convenience for callers that want a stable id even when uuid is absent.
    var stableId: String {
        uuid ?? UUID().uuidString
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
