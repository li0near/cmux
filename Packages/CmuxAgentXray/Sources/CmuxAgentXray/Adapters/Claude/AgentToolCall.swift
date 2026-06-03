import Foundation

/// Internal accumulator for one tool call as the transcript builder
/// folds in `tool_use` / `tool_result` blocks across multiple JSONL
/// lines. Converted to a public `ToolEntry` at flush time, with the
/// `Header` and `Body` constructed from these fields.
///
/// Kept internal: callers consume the final `AgentTurn.subEntries`
/// list. The accumulator's "incremental" shape (separate `result` and
/// `inputDetail` strings, mutable `isError` and `durationMs`) is a
/// builder convenience and not part of the public model.
struct AgentToolCall: Equatable {
    let id: String
    let name: String
    let summary: String
    let inputDetail: String
    let result: String?
    let isError: Bool
    let subagentType: String?
    let teamMemberName: String?
    let teamName: String?
    let durationMs: Int?
    let sidechainTranscript: [Entry]?

    init(
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
        self.durationMs = durationMs
        self.sidechainTranscript = sidechainTranscript
    }
}
