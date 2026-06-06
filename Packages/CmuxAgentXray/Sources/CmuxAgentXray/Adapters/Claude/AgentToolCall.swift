import Foundation

/// Internal accumulator for one tool call as the transcript builder
/// folds in `tool_use` / `tool_result` blocks across multiple JSONL
/// lines. Converted to a public `ToolEntry` at flush time, with the
/// `Header` and `Body` constructed from these fields.
///
/// Kept internal: callers consume the final `AgentEntry.subEntries`
/// list. The accumulator's "incremental" shape (separate `result` and
/// `inputDetail` strings, mutable `isError` and `durationMs`) is a
/// builder convenience and not part of the public model.
struct AgentToolCall: Equatable {
    let id: String
    let name: String
    let summary: String
    let inputDetail: String
    /// Pre-built sections for the result body (one per `tool_result.content[]`
    /// block). nil means the result hasn't arrived yet (call is pending).
    /// Empty array means the result arrived but contained no
    /// renderable blocks. The flush-time code appends these directly
    /// after the input section.
    let result: [Section]?
    let isError: Bool
    let subagentType: String?
    let teamMemberName: String?
    let teamName: String?
    let mcpServer: String?
    let durationMs: Int?
    let sidechainTranscript: [Entry]?

    init(
        id: String,
        name: String,
        summary: String,
        inputDetail: String,
        result: [Section]?,
        isError: Bool,
        subagentType: String? = nil,
        teamMemberName: String? = nil,
        teamName: String? = nil,
        mcpServer: String? = nil,
        durationMs: Int? = nil,
        sidechainTranscript: [Entry]? = nil
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
        self.mcpServer = mcpServer
        self.durationMs = durationMs
        self.sidechainTranscript = sidechainTranscript
    }

    /// Return a copy of this call with the result-side fields filled in
    /// (or overwritten). The "in" fields (`id`, `name`, `summary`,
    /// `inputDetail`, sub-agent metadata) carry through unchanged.
    /// Used when a `tool_result` JSONL line lands for an in-flight tool.
    func withResult(
        _ result: [Section],
        isError: Bool,
        durationMs: Int?
    ) -> AgentToolCall {
        AgentToolCall(
            id: id,
            name: name,
            summary: summary,
            inputDetail: inputDetail,
            result: result,
            isError: isError,
            subagentType: subagentType,
            teamMemberName: teamMemberName,
            teamName: teamName,
            mcpServer: mcpServer,
            durationMs: durationMs,
            sidechainTranscript: sidechainTranscript
        )
    }

    /// Attach a sidechain transcript at flush time without rewriting
    /// the rest of the fields. Used when the parent `Task`/`Agent`
    /// tool's sub-agent transcript is collated post-hoc.
    func withSidechain(_ transcript: [Entry]) -> AgentToolCall {
        AgentToolCall(
            id: id,
            name: name,
            summary: summary,
            inputDetail: inputDetail,
            result: result,
            isError: isError,
            subagentType: subagentType,
            teamMemberName: teamMemberName,
            teamName: teamName,
            mcpServer: mcpServer,
            durationMs: durationMs,
            sidechainTranscript: transcript
        )
    }
}
