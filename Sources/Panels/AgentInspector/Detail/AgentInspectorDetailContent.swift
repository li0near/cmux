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
        // Phase B detail surfaces.
        case assistantResponse
        case abandonedBranch(rewindIndex: Int, totalRewinds: Int)
        case subagentTranscript(toolName: String, subagentType: String?)
        case skillBody(skillName: String)
        case slashCommandBody(commandName: String)
        case systemReminderBody
        case recapBody
        case localCommandCaveatBody
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
        case .assistantResponse(let id):
            guard case .ai(let ai) = chunk, ai.id == id else { return nil }
            let trimmed = ai.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lineCount = ai.assistantText.split(separator: "\n", omittingEmptySubsequences: false).count
            return AgentInspectorDetailContent(
                title: "Assistant response",
                subtitle: "from \(chunkTimestamp) · \(lineCount) lines",
                body: ai.assistantText,
                sourceChunkId: id,
                kind: .assistantResponse
            )
        case .abandonedBranch(let branchRootUuid):
            guard case .meta(.branchLink(let branch)) = chunk, branch.id == branchRootUuid else { return nil }
            // Abandoned branches don't carry their inner chunk list on the
            // BranchLink chunk itself — the renderer only knows summary stats.
            // The detail panel surfaces the metadata; future work can pass
            // the actual abandoned chunk list through if needed.
            let preview = branch.firstPromptPreview ?? "(no prompt preview)"
            return AgentInspectorDetailContent(
                title: "Abandoned branch — rewind \(branch.rewindIndex) of \(branch.totalRewinds)",
                subtitle: "\(branch.chunkCount) chunks · diverged at \(chunkTimestamp)",
                body: preview,
                sourceChunkId: branchRootUuid,
                kind: .abandonedBranch(
                    rewindIndex: branch.rewindIndex,
                    totalRewinds: branch.totalRewinds
                )
            )
        case .subagentTranscript(let chunkId, let toolId):
            guard case .ai(let ai) = chunk,
                  ai.id == chunkId,
                  let tool = ai.toolCalls.first(where: { $0.id == toolId }),
                  let transcript = tool.sidechainTranscript else { return nil }
            let summaryBody = transcript.compactMap { tx -> String? in
                if case .ai(let a) = tx, !a.assistantText.isEmpty { return a.assistantText }
                if case .user(let u) = tx, !u.text.isEmpty { return u.text }
                return nil
            }.joined(separator: "\n\n— —\n\n")
            return AgentInspectorDetailContent(
                title: "Sub-agent transcript · \(tool.name)",
                subtitle: "from \(chunkTimestamp) · \(transcript.count) chunks",
                body: summaryBody.isEmpty ? "(empty sub-agent transcript)" : summaryBody,
                sourceChunkId: chunkId,
                kind: .subagentTranscript(toolName: tool.name, subagentType: tool.subagentType)
            )
        case .skillBody(let id):
            guard case .meta(.skillTitle(let skill)) = chunk, skill.id == id else { return nil }
            return AgentInspectorDetailContent(
                title: "Skill · \(skill.skillName)",
                subtitle: "from \(chunkTimestamp) · \(skill.basePath)",
                body: skill.body,
                sourceChunkId: id,
                kind: .skillBody(skillName: skill.skillName)
            )
        case .slashCommandBody(let id):
            // Slash-command bodies aren't a discrete MetaChunk kind in
            // Phase A; they share routing with skills. Resolve from the
            // SlashCmdInputChunk if its args carry an embedded body, else
            // fall back to nil.
            guard case .meta(.slashCmdInput(let cmd)) = chunk, cmd.id == id else { return nil }
            let body = cmd.args ?? ""
            guard !body.isEmpty else { return nil }
            return AgentInspectorDetailContent(
                title: "Slash command · /\(cmd.commandName)",
                subtitle: "from \(chunkTimestamp)",
                body: body,
                sourceChunkId: id,
                kind: .slashCommandBody(commandName: cmd.commandName)
            )
        case .systemReminderBody(let id):
            guard case .meta(.systemReminder(let r)) = chunk, r.id == id else { return nil }
            return AgentInspectorDetailContent(
                title: "System reminder",
                subtitle: "from \(chunkTimestamp)",
                body: r.body,
                sourceChunkId: id,
                kind: .systemReminderBody
            )
        case .recapBody(let id):
            guard case .meta(.recap(let r)) = chunk, r.id == id else { return nil }
            return AgentInspectorDetailContent(
                title: "Recap",
                subtitle: "from \(chunkTimestamp)",
                body: r.body,
                sourceChunkId: id,
                kind: .recapBody
            )
        case .localCommandCaveatBody(let id):
            guard case .meta(.localCommandCaveat(let r)) = chunk, r.id == id else { return nil }
            return AgentInspectorDetailContent(
                title: "Local command caveat",
                subtitle: "from \(chunkTimestamp)",
                body: r.body,
                sourceChunkId: id,
                kind: .localCommandCaveatBody
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
