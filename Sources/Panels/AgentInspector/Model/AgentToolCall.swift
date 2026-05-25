import Foundation

/// Captures one tool invocation within an `AIChunk`. Lives in the public
/// agent-agnostic model layer so both Claude and Codex adapters can produce
/// it.
public struct AgentToolCall: Equatable, Sendable, Identifiable {
    public let id: String
    /// Tool name as reported by the agent (e.g. "Read", "Bash", "Edit", "Task").
    public let name: String
    /// One-line summary derived from the tool's input arguments. Best-effort —
    /// long inputs are truncated.
    public let summary: String
    /// Pretty-formatted full input (multi-line, JSON-ish). Always non-nil
    /// but may be empty for trivial inputs.
    public let inputDetail: String
    /// Tool result body (full text from the JSONL entry, may be large).
    /// Nil while pending.
    public let result: String?
    /// Whether the tool call's result was an error.
    public let isError: Bool
    /// For Task tools: the subagent's intended type (e.g. "general-purpose"),
    /// extracted from the `subagent_type` input field. Nil for non-Task tools.
    public let subagentType: String?
    /// For Task tools that target a team member: the `name` field from the
    /// Task input (e.g. "Alice"). Mirrors claude-devtools' team metadata
    /// extraction at `SubagentResolver.ts:322-326`. Preferred over
    /// `subagentType` for the chip label when present.
    public let teamMemberName: String?
    /// For Task tools that target a team member: the `team_name` from the
    /// Task input (e.g. "engineering"). Currently unused by the renderer but
    /// kept for symmetry with claude-devtools' extraction.
    public let teamName: String?
    /// Duration in milliseconds between the tool's `tool_use` entry and its
    /// matching `tool_result` entry in the JSONL, when both timestamps are
    /// known. Nil when the tool is still pending or timestamps are missing.
    public let durationMs: Int?
    /// For `Task`/`Agent` tool calls: the chunks emitted by the spawned
    /// sub-agent's sidechain transcript. nil for non-Task tools and for
    /// Task tools whose sidechain hasn't streamed yet. Phase B renders
    /// this as a `↳ Sub-agent transcript` link inside the tool's row,
    /// opening a detail tab via
    /// `AgentInspectorDetailContent.subagentTranscript`.
    public let sidechainTranscript: [AgentChunk]?

    /// All optional fields default to nil so existing call sites that don't
    /// supply them continue to compile unchanged. Adapters that have the
    /// data (e.g. ClaudeChunkBuilder pulls `team_name` / `name` from Task
    /// inputs and computes `durationMs` from line timestamps) populate them
    /// at construction; adapters that don't (Codex rollouts, which lack
    /// per-line timestamps) leave them nil and the renderer hides the
    /// corresponding UI elements gracefully.
    public init(
        id: String,
        name: String,
        summary: String,
        inputDetail: String,
        result: String?,
        isError: Bool,
        subagentType: String? = nil,
        teamMemberName: String? = nil,
        teamName: String? = nil,
        durationMs: Int? = nil,
        sidechainTranscript: [AgentChunk]? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.inputDetail = inputDetail
        self.result = result
        self.isError = isError
        self.subagentType = subagentType
        self.teamMemberName = teamMemberName
        self.teamName = teamName
        self.durationMs = durationMs
        self.sidechainTranscript = sidechainTranscript
    }
}
