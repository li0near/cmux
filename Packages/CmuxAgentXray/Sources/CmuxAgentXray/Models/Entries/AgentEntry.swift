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

    /// Canonical ordered child projection. Holds `.text` / `.tool`
    /// `Entry` cases (post-G1.5 the prior dedicated `SubEntry` enum is
    /// merged into `Entry`). The builder enforces the
    /// "only `.text` / `.tool` at this depth" convention; runtime
    /// asserts in ``TranscriptRoot/append(parent:entry:)`` catch any
    /// regression that places a non-text/tool entry here.
    public let subEntries: [Entry]

    public init(
        id: EntryID,
        header: Header,
        body: Body,
        usage: TokenUsage,
        stopReason: String? = nil,
        perTurnDurationMs: Int? = nil,
        messageCount: Int? = nil,
        model: String? = nil,
        endTime: Date? = nil,
        subEntries: [Entry] = []
    ) {
        self.id = id
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

    /// Wall-clock timestamp of the turn's start, projected from
    /// `header.timeMarker.clock`. Nil when the header has no clock
    /// marker.
    public var timestamp: Date? { header.timeMarker?.clockDate }

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

/// `TextSubEntry` and `ToolEntry` carry the same shape — `id`,
/// `parentEntryID`, `timestamp` (computed from `header.timeMarker`),
/// `header`, `body` — but a protocol formalizing that contract bought
/// nothing because the enum `AgentEntry.SubEntry` is the dispatch and
/// equality surface (existentials don't synthesize Equatable). The two
/// concrete types conform to `Identifiable, Equatable, Sendable`
/// directly.

/// One assistant-side text block — either model "thinking" reasoning
/// or an "assistant" response message. Both share the same shape; the
/// `kind` enum drives per-kind chrome at the view layer (icon, color,
/// italic flag, localized label) while the data model stays unified.
///
/// Multiple `TextSubEntry` sub-entries can appear in a single
/// `AgentEntry`, interleaved with `ToolEntry` in JSONL arrival order.
/// Body carries the text in a single `.text` section so the renderer
/// caps it inline with the standard overflow link, identical to how
/// tool input/result blocks are surfaced.
public struct TextSubEntry: Identifiable, Equatable, Sendable {
    /// Discriminator between thinking blocks and final assistant text
    /// blocks. Drives view-layer styling without splitting the data
    /// model.
    public enum Kind: Equatable, Sendable {
        case thinking
        case assistant
    }

    public let kind: Kind
    public let id: EntryID
    public let parentEntryID: EntryID
    public let header: Header
    public let body: Body
    /// Word count of the text — drives the trailing `N words` pill on
    /// the sub-entry header.
    public let wordCount: Int

    public init(
        kind: Kind,
        id: EntryID,
        parentEntryID: EntryID,
        header: Header,
        body: Body,
        wordCount: Int
    ) {
        self.kind = kind
        self.id = id
        self.parentEntryID = parentEntryID
        self.header = header
        self.body = body
        self.wordCount = wordCount
    }

    public var timestamp: Date? { header.timeMarker?.clockDate }
}

/// One tool invocation inside an assistant turn. Body normally carries
/// `[.text(input), .text(result)?]`; for Task / Agent tools that spawn a
/// sub-agent, the spawned transcript appears as a trailing
/// `.subentries(...)` section. The renderer policy decides whether to
/// surface the sub-transcript inline or as a link to a detail tab.
public struct ToolEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let parentEntryID: EntryID
    public let header: Header
    public let body: Body

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
    /// Server name parsed from MCP tool names of the form
    /// `mcp__<server>__<tool>` (e.g. `"playwright"`). nil for built-in
    /// tools whose names don't carry the `mcp__` prefix. Drives the
    /// per-tool server chip in the sub-row header.
    public let mcpServer: String?
    /// `file_path` from the tool's input for tools that carry it
    /// (Read / Edit / Write / MultiEdit). Used by the detail-tab
    /// resolver to set `ContentType` to `.code(language:)` based on
    /// the extension; the host materializer then writes a temp file
    /// with the matching extension and cmux's `FilePreviewPanel` +
    /// highlight.js color the body.
    public let inputFilePath: String?

    public init(
        id: EntryID,
        parentEntryID: EntryID,
        header: Header,
        body: Body,
        status: Status,
        durationMs: Int? = nil,
        subagentType: String? = nil,
        teamMemberName: String? = nil,
        teamName: String? = nil,
        mcpServer: String? = nil,
        inputFilePath: String? = nil
    ) {
        self.id = id
        self.parentEntryID = parentEntryID
        self.header = header
        self.body = body
        self.status = status
        self.durationMs = durationMs
        self.subagentType = subagentType
        self.teamMemberName = teamMemberName
        self.teamName = teamName
        self.mcpServer = mcpServer
        self.inputFilePath = inputFilePath
    }

    /// Wall-clock timestamp, projected from `header.timeMarker.clock`.
    /// Tools normally carry `.duration` instead, so this returns nil.
    public var timestamp: Date? { header.timeMarker?.clockDate }

    /// Tool name (e.g. "Read", "Bash"). The builder always sets
    /// `header.name` to the JSONL `name` field for tool sub-entries —
    /// this accessor surfaces it as a non-optional convenience for
    /// detail-tab routing and the view layer.
    public var toolName: String { header.name ?? "" }

    public enum Status: Equatable, Sendable {
        case pending, ok, error
    }

    // MARK: - Body section conventions

    /// Tool body sections are constructed in this order by the
    /// transcript builder:
    ///   sections[0]            — `.text([input], .normal)`
    ///   sections[1] (optional) — `.text([result], .normal/.error)`
    ///
    /// Sub-agent (Task / Agent tool) transcripts are NOT carried on
    /// the tool entry — the proper data shape surfaces them as
    /// top-level `AgentEntry` rows in the main transcript. That
    /// implementation is a follow-up; until it lands, sidechain
    /// transcripts are not rendered through the detail-tab path.
}

// (`AssistantTextEntry` and `ThinkingEntry` are gone — use
//  `TextSubEntry(kind: .assistant, ...)` and `TextSubEntry(kind: .thinking, ...)`.)
