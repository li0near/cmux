public import Foundation

/// One assistant turn — the only `Entry` variant that contains nested
/// children. Captures everything the agent did in response to one user
/// prompt: thinking blocks, tool invocations, and the final assistant
/// text. Token usage and per-turn metadata travel on the turn itself.
///
/// `subEntries` is the canonical ordered projection of the turn's
/// content, normally `[thinking?, ...tools, assistantText?]`. The body's
/// `.subentries(...)` section mirrors `subEntries` so the renderer can
/// walk children uniformly via `body.sections` regardless of variant.
public struct AgentEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body

    /// Aggregated token usage across every assistant message folded into
    /// this turn.
    public let usage: TokenUsage
    /// `stop_reason` from the **last** assistant message folded into this
    /// turn (e.g. "end_turn", "max_tokens", "pause_turn").
    public let stopReason: String?
    /// Per-turn aggregate duration sourced from Claude's
    /// `system.subtype: turn_duration` JSONL entry, when available.
    /// Authoritative source — preferred over `(endTime − startTime)` when
    /// present. nil for Codex, older Claude versions, or live
    /// (in-progress) turns.
    public let perTurnDurationMs: Int?
    /// Per-turn aggregate message count from the same `turn_duration`
    /// entry.
    public let messageCount: Int?
    /// Optional model id reported by the assistant message
    /// (e.g. "claude-sonnet-4-5"). Friendly display form lives in
    /// `header.label` (e.g. "Sonnet 4.5").
    public let model: String?
    /// Timestamp of the last message folded into this turn. Combined
    /// with `timestamp` (start) gives a fallback duration when
    /// `perTurnDurationMs` is absent.
    public let endTime: Date?

    /// Canonical ordered child projection (typed-narrow: only the three
    /// kinds that ever appear inside an agent turn). Mirrored in
    /// `body.sections`.
    public let subEntries: [SubEntry]

    public init(
        id: EntryID,
        timestamp: Date?,
        header: Header,
        body: Body,
        usage: TokenUsage,
        stopReason: String? = nil,
        perTurnDurationMs: Int? = nil,
        messageCount: Int? = nil,
        model: String? = nil,
        endTime: Date? = nil,
        subEntries: [SubEntry] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.header = header
        self.body = body
        self.usage = usage
        self.stopReason = stopReason
        self.perTurnDurationMs = perTurnDurationMs
        self.messageCount = messageCount
        self.model = model
        self.endTime = endTime
        self.subEntries = subEntries
    }

    /// Type-system-narrowed child kinds. These three variants only ever
    /// appear inside an `AgentEntry` — they never exist as top-level
    /// transcript entries.
    public enum SubEntry: Identifiable, Equatable, Sendable {
        case thinking(ThinkingEntry)
        case tool(ToolEntry)
        case assistantText(AssistantTextEntry)

        public var id: EntryID {
            switch self {
            case .thinking(let t):       return t.id
            case .tool(let t):           return t.id
            case .assistantText(let a):  return a.id
            }
        }

        public var header: Header {
            switch self {
            case .thinking(let t):       return t.header
            case .tool(let t):           return t.header
            case .assistantText(let a):  return a.header
            }
        }

        public var body: Body {
            switch self {
            case .thinking(let t):       return t.body
            case .tool(let t):           return t.body
            case .assistantText(let a):  return a.body
            }
        }

        public var timestamp: Date? {
            switch self {
            case .thinking(let t):       return t.timestamp
            case .tool(let t):           return t.timestamp
            case .assistantText(let a):  return a.timestamp
            }
        }
    }

    /// Aggregated token counts across the turn. All fields can be 0 if
    /// the JSONL didn't include usage info (older entries, or
    /// non-assistant messages).
    public struct TokenUsage: Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheCreationTokens: Int

        public init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheCreationTokens: Int = 0
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
        }

        public static let zero = TokenUsage()
    }
}

// MARK: - Sub-entry concrete types

/// Extended-thinking projection — one `thinking` content block inside an
/// assistant message. Body holds the reasoning text in a single `.text`
/// section with `style: .thinking`.
public struct ThinkingEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let parentEntryID: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body

    public init(
        id: EntryID,
        parentEntryID: EntryID,
        timestamp: Date?,
        header: Header,
        body: Body
    ) {
        self.id = id
        self.parentEntryID = parentEntryID
        self.timestamp = timestamp
        self.header = header
        self.body = body
    }
}

/// One tool invocation inside an assistant turn. Body normally carries
/// `[.text(input), .text(result)?]`; for Task / Agent tools that spawn a
/// sub-agent, the spawned transcript appears as a trailing
/// `.subentries(...)` section. The renderer policy decides whether to
/// surface the sub-transcript inline or as a link to a detail tab.
public struct ToolEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body

    /// Tool name as reported by the agent (e.g. "Read", "Bash").
    public let toolName: String
    /// Three-state tool status. `pending` = awaiting result; `ok` =
    /// completed without error; `error` = result was an error.
    public let status: Status
    /// Duration in milliseconds between `tool_use` and `tool_result`
    /// entries when both timestamps are known. nil while pending.
    public let durationMs: Int?
    /// Sub-agent metadata for `Task` / `Agent` tools — `subagent_type`,
    /// `name`, `team_name`. nil for non-Task tools.
    public let subagentType: String?
    public let teamMemberName: String?
    public let teamName: String?

    public init(
        id: EntryID,
        timestamp: Date?,
        header: Header,
        body: Body,
        toolName: String,
        status: Status,
        durationMs: Int? = nil,
        subagentType: String? = nil,
        teamMemberName: String? = nil,
        teamName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.header = header
        self.body = body
        self.toolName = toolName
        self.status = status
        self.durationMs = durationMs
        self.subagentType = subagentType
        self.teamMemberName = teamMemberName
        self.teamName = teamName
    }

    public enum Status: Equatable, Sendable {
        case pending, ok, error
    }

    // MARK: - Body section conventions

    /// Tool body sections are constructed in this order by the
    /// transcript builder:
    ///   sections[0]            — `.text([input], .normal)`
    ///   sections[1] (optional) — `.text([result], .normal/.error)`
    ///   trailing `.subentries` (optional) — sub-agent transcript
    /// The accessors below project that convention into per-slot
    /// values for detail-tab resolution and tests, without committing
    /// to a new field on the struct.

    /// Inline text content for the tool's input slot.
    public var inputDetail: String? {
        guard case .text(let blocks, _) = body.sections.first else { return nil }
        return blocks.joined(separator: "\n")
    }

    /// Inline text content for the tool's result slot, if any.
    public var resultDetail: String? {
        guard body.sections.count >= 2,
              case .text(let blocks, _) = body.sections[1] else { return nil }
        return blocks.joined(separator: "\n")
    }

    /// Sub-agent transcript carried on the tool, if any. Walks
    /// `body.sections` for the first `.subentries(...)` payload.
    public var sidechainTranscript: [Entry]? {
        for section in body.sections {
            if case .subentries(let entries) = section { return entries }
        }
        return nil
    }
}

/// Final assistant-text projection of a turn. Body is empty
/// (Variant A header-only): the click opens the full text in a sibling
/// detail tab, never inline. `fullBody` carries the entire text the
/// detail tab renders; `wordCount` is the pre-counted "N words" pill.
public struct AssistantTextEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let parentEntryID: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body  // always empty by convention; carried for protocol uniformity
    public let fullBody: String
    public let wordCount: Int

    public init(
        id: EntryID,
        parentEntryID: EntryID,
        timestamp: Date?,
        header: Header,
        fullBody: String,
        wordCount: Int
    ) {
        self.id = id
        self.parentEntryID = parentEntryID
        self.timestamp = timestamp
        self.header = header
        self.body = .empty
        self.fullBody = fullBody
        self.wordCount = wordCount
    }
}
