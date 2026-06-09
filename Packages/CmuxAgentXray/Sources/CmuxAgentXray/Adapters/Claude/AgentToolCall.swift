import Foundation

/// Internal accumulator for one tool call's parser outputs. Built
/// once at `tool_use` block ingest time from `ToolInputParser` /
/// `MCPToolNameParser` outputs, then handed to `makeToolEntry` which
/// constructs the public `ToolEntry`. The accumulator's "many
/// fields" shape lets parsers run in one pass and the entry-build
/// in a second; it is not part of the public model.
///
/// Post-G6 the accumulator carries no result-side state — `tool_result`
/// blocks mutate the appended `ToolEntry` in place via
/// ``ToolResultUpdate``, not by re-rendering this struct with result
/// sections.
struct AgentToolCall: Equatable {
    let id: String
    let name: String
    let summary: String
    let inputDetail: String
    let subagentType: String?
    let teamMemberName: String?
    let teamName: String?
    let mcpServer: String?
    /// `file_path` from the tool's input JSON (Read / Edit / Write /
    /// MultiEdit). Forwarded to `ToolEntry.inputFilePath` so the
    /// detail-tab resolver can pick a `.code(language:)` ContentType
    /// from the extension (cmux's `FilePreviewPanel` then materializes
    /// the temp file with the right ext + highlight.js coloring).
    let inputFilePath: String?
    /// Precomputed diff-styled body sections for `Edit` / `MultiEdit`
    /// tools — one `.diffRemoved` + `.diffAdded` pair per edit, in
    /// arrival order. Populated by `ToolInputParser.diffSections(...)`
    /// at parse time so `makeToolEntry` emits colored old/new blocks
    /// instead of the default single `.text([inputDetail], .normal)`
    /// section. Nil for any non-edit tool.
    let diffSections: [Section]?

    init(
        id: String,
        name: String,
        summary: String,
        inputDetail: String,
        subagentType: String? = nil,
        teamMemberName: String? = nil,
        teamName: String? = nil,
        mcpServer: String? = nil,
        inputFilePath: String? = nil,
        diffSections: [Section]? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.inputDetail = inputDetail
        self.subagentType = subagentType
        self.teamMemberName = teamMemberName
        self.teamName = teamName
        self.mcpServer = mcpServer
        self.inputFilePath = inputFilePath
        self.diffSections = diffSections
    }
}
