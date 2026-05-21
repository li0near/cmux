import Foundation

/// Static content shown by an `AgentInspectorPanel` when its `mode` is
/// `.detail(content:)`. Created by the live inspector when a chunk row's
/// `↗ Open detail` link is clicked because an expandable section overflowed
/// the inline cap.
///
/// The detail panel reuses the inspector's renderer (palette, badges, layout)
/// in `.fullDetail` mode so users get a consistent look — it's the *same*
/// panel kind, just frozen on one chunk's expanded slice.
struct AgentInspectorDetailContent: Equatable {
    /// Title shown in the tab bar and detail header (e.g. "Tool result · Read /foo.ts").
    let title: String
    /// Optional subtitle (e.g. "from chunk at 14:23:01 · 1.2k lines").
    let subtitle: String?
    /// Full unfolded body — rendered without truncation.
    let body: String
    /// Source chunk id, kept for future cross-references / search.
    let sourceChunkId: String
    /// Discriminator for styling (color of the title accent, glyph).
    let kind: Kind

    enum Kind: Equatable {
        case userPrompt
        case thinking
        case systemOutput
        case toolInput(toolName: String)
        case toolResult(toolName: String, isError: Bool)
    }
}

extension AgentInspectorDetailContent {
    /// Build a detail content from a request and the source `AgentChunk`.
    /// Returns nil when the request can't be resolved against the chunk
    /// (chunk type mismatch, missing tool id, empty content).
    static func resolve(
        request: InspectorDetailRequest,
        chunk: AgentChunk
    ) -> AgentInspectorDetailContent? {
        let chunkTimestamp = formatTimestamp(chunk.startTime)
        switch request {
        case .userPrompt(let id):
            guard case .user(let user) = chunk, user.id == id else { return nil }
            let trimmed = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AgentInspectorDetailContent(
                title: "User prompt",
                subtitle: "from \(chunkTimestamp) · \(user.text.count) chars",
                body: user.text,
                sourceChunkId: id,
                kind: .userPrompt
            )
        case .thinking(let id):
            guard case .ai(let ai) = chunk, ai.id == id else { return nil }
            let trimmed = ai.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lineCount = ai.thinkingText.split(separator: "\n", omittingEmptySubsequences: false).count
            return AgentInspectorDetailContent(
                title: "Thinking",
                subtitle: "from \(chunkTimestamp) · \(lineCount) lines",
                body: ai.thinkingText,
                sourceChunkId: id,
                kind: .thinking
            )
        case .systemOutput(let id):
            guard case .system(let sys) = chunk, sys.id == id else { return nil }
            let trimmed = sys.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AgentInspectorDetailContent(
                title: "System output",
                subtitle: "from \(chunkTimestamp)",
                body: sys.output,
                sourceChunkId: id,
                kind: .systemOutput
            )
        case .toolInput(let chunkId, let toolId):
            guard case .ai(let ai) = chunk,
                  ai.id == chunkId,
                  let tool = ai.toolCalls.first(where: { $0.id == toolId }) else { return nil }
            let trimmed = tool.inputDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AgentInspectorDetailContent(
                title: "Tool input · \(tool.name)",
                subtitle: "from \(chunkTimestamp)\(tool.summary.isEmpty ? "" : " · \(tool.summary)")",
                body: tool.inputDetail,
                sourceChunkId: chunkId,
                kind: .toolInput(toolName: tool.name)
            )
        case .toolResult(let chunkId, let toolId):
            guard case .ai(let ai) = chunk,
                  ai.id == chunkId,
                  let tool = ai.toolCalls.first(where: { $0.id == toolId }),
                  let result = tool.result else { return nil }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AgentInspectorDetailContent(
                title: "Tool result · \(tool.name)",
                subtitle: "from \(chunkTimestamp)\(tool.summary.isEmpty ? "" : " · \(tool.summary)")",
                body: result,
                sourceChunkId: chunkId,
                kind: .toolResult(toolName: tool.name, isError: tool.isError)
            )
        }
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
