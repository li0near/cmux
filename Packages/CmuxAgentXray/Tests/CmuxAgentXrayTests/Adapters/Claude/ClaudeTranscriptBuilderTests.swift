import Foundation
import Testing
@testable import CmuxAgentXray

/// Sub-entry arrival-order regression: thinking + assistantText sub-entries
/// must interleave with tool sub-entries in the order Claude emitted them
/// in the JSONL, instead of being string-coalesced and pinned to a fixed
/// `[thinking?, …tools, assistantText?]` shape.
///
/// Predecessor builder collapsed every assistant text block into one
/// `AssistantTextEntry` placed *after* every tool, destroying the
/// chronological "narrate → tool → narrate → tool" flow visible in the
/// raw transcript. These tests pin the new arrival-order behavior.
@Suite("ClaudeTranscriptBuilder — sub-entry arrival order")
struct ClaudeTranscriptBuilderTests {

    private func decodeLine(_ json: String) throws -> ClaudeJSONLLine {
        try AgentXrayJSON.decoder.decode(
            ClaudeJSONLLine.self,
            from: Data(json.utf8)
        )
    }

    /// Build a minimal turn from a user prompt and one or more
    /// assistant lines, run the builder, and return the resulting
    /// `AgentEntry` (or fail).
    private func buildAgentEntry(
        userUuid: String = "u1",
        assistantLines: [String]
    ) throws -> AgentEntry {
        let userJSON = #"""
        {
          "type": "user",
          "uuid": "\#(userUuid)",
          "parentUuid": null,
          "timestamp": "2026-06-05T10:00:00.000Z",
          "message": {"role": "user", "content": "go"}
        }
        """#
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(userJSON))
        for line in assistantLines {
            try builder.ingest(decodeLine(line))
        }
        let entries = builder.transcript()
        guard let agent = entries.compactMap({ entry -> AgentEntry? in
            if case .agent(let a) = entry { return a }
            return nil
        }).first else {
            Issue.record("No AgentEntry in transcript")
            return AgentEntry(
                id: .fromJSONL("missing"),
                header: Header(),
                body: .empty,
                usage: .zero
            )
        }
        return agent
    }

    private func makeAssistantTextLine(
        uuid: String,
        parentUuid: String,
        text: String,
        timestamp: String = "2026-06-05T10:00:01.000Z"
    ) -> String {
        return #"""
        {
          "type": "assistant",
          "uuid": "\#(uuid)",
          "parentUuid": "\#(parentUuid)",
          "timestamp": "\#(timestamp)",
          "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": "\#(text)"}]
          }
        }
        """#
    }

    private func makeAssistantToolUseLine(
        uuid: String,
        parentUuid: String,
        toolUseId: String,
        toolName: String,
        timestamp: String = "2026-06-05T10:00:01.000Z"
    ) -> String {
        return #"""
        {
          "type": "assistant",
          "uuid": "\#(uuid)",
          "parentUuid": "\#(parentUuid)",
          "timestamp": "\#(timestamp)",
          "message": {
            "role": "assistant",
            "content": [{
              "type": "tool_use",
              "id": "\#(toolUseId)",
              "name": "\#(toolName)",
              "input": {}
            }]
          }
        }
        """#
    }

    private func makeAssistantThinkingLine(
        uuid: String,
        parentUuid: String,
        thinking: String,
        timestamp: String = "2026-06-05T10:00:01.000Z"
    ) -> String {
        return #"""
        {
          "type": "assistant",
          "uuid": "\#(uuid)",
          "parentUuid": "\#(parentUuid)",
          "timestamp": "\#(timestamp)",
          "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": "\#(thinking)"}]
          }
        }
        """#
    }

    @Test("Text → tool → text → tool → text produces sub-entries in arrival order")
    func interleavedAssistantTextAndTools() throws {
        let lines = [
            makeAssistantTextLine(uuid: "a1", parentUuid: "u1", text: "Let me read the file"),
            makeAssistantToolUseLine(uuid: "a2", parentUuid: "a1", toolUseId: "tool-1", toolName: "Read"),
            makeAssistantTextLine(uuid: "a3", parentUuid: "a2", text: "Now I see the issue"),
            makeAssistantToolUseLine(uuid: "a4", parentUuid: "a3", toolUseId: "tool-2", toolName: "Edit"),
            makeAssistantTextLine(uuid: "a5", parentUuid: "a4", text: "Fix applied"),
        ]
        let agent = try buildAgentEntry(assistantLines: lines)
        #expect(agent.subEntries.count == 5)

        let kinds: [String] = agent.subEntries.map { sub in
            switch sub {
            case .text(let t):
                return t.kind == .thinking ? "thinking" : "assistantText"
            case .tool:
                return "tool"
            case .user, .agent, .system, .compact, .synthesized:
                return "<unexpected>"
            }
        }
        #expect(kinds == ["assistantText", "tool", "assistantText", "tool", "assistantText"])
    }

    @Test("Multiple thinking blocks across multiple lines are NOT coalesced")
    func multipleThinkingBlocksDoNotCoalesce() throws {
        let lines = [
            makeAssistantThinkingLine(uuid: "a1", parentUuid: "u1", thinking: "First thought"),
            makeAssistantToolUseLine(uuid: "a2", parentUuid: "a1", toolUseId: "tool-1", toolName: "Read"),
            makeAssistantThinkingLine(uuid: "a3", parentUuid: "a2", thinking: "Second thought"),
        ]
        let agent = try buildAgentEntry(assistantLines: lines)
        #expect(agent.subEntries.count == 3)

        let thinkingCount = agent.subEntries.filter {
            if case .text(let t) = $0, t.kind == .thinking { return true }
            return false
        }.count
        #expect(thinkingCount == 2)
    }

    @Test("Thinking → text → tool → thinking → text → tool preserves full chronology")
    func interleavedThinkingTextTools() throws {
        let lines = [
            makeAssistantThinkingLine(uuid: "a1", parentUuid: "u1", thinking: "Plan"),
            makeAssistantTextLine(uuid: "a2", parentUuid: "a1", text: "Reading files"),
            makeAssistantToolUseLine(uuid: "a3", parentUuid: "a2", toolUseId: "tool-1", toolName: "Read"),
            makeAssistantThinkingLine(uuid: "a4", parentUuid: "a3", thinking: "Found it"),
            makeAssistantTextLine(uuid: "a5", parentUuid: "a4", text: "Editing"),
            makeAssistantToolUseLine(uuid: "a6", parentUuid: "a5", toolUseId: "tool-2", toolName: "Edit"),
        ]
        let agent = try buildAgentEntry(assistantLines: lines)
        let kinds: [String] = agent.subEntries.map { sub in
            switch sub {
            case .text(let t):
                return t.kind == .thinking ? "thinking" : "assistantText"
            case .tool:
                return "tool"
            case .user, .agent, .system, .compact, .synthesized:
                return "<unexpected>"
            }
        }
        #expect(kinds == ["thinking", "assistantText", "tool", "thinking", "assistantText", "tool"])
    }

    // MARK: - G3 risk-area fixtures (skeleton-in-Transcript)

    /// Helper: build a tool_use line with a custom input dict
    /// (so we can verify last-write-wins on duplicate tool_use).
    private func makeAssistantToolUseLineWithInput(
        uuid: String,
        parentUuid: String,
        toolUseId: String,
        toolName: String,
        inputJSON: String,
        timestamp: String = "2026-06-05T10:00:01.000Z"
    ) -> String {
        return #"""
        {
          "type": "assistant",
          "uuid": "\#(uuid)",
          "parentUuid": "\#(parentUuid)",
          "timestamp": "\#(timestamp)",
          "message": {
            "role": "assistant",
            "content": [{
              "type": "tool_use",
              "id": "\#(toolUseId)",
              "name": "\#(toolName)",
              "input": \#(inputJSON)
            }]
          }
        }
        """#
    }

    /// Helper: a user line bearing a tool_result block. Routed by the
    /// builder's `classifyUserLine` to the agent path so it merges
    /// into the in-flight skeleton.
    private func makeToolResultLine(
        uuid: String,
        parentUuid: String,
        toolUseId: String,
        resultText: String,
        isError: Bool = false,
        timestamp: String = "2026-06-05T10:00:02.000Z"
    ) -> String {
        return #"""
        {
          "type": "user",
          "uuid": "\#(uuid)",
          "parentUuid": "\#(parentUuid)",
          "timestamp": "\#(timestamp)",
          "message": {
            "role": "user",
            "content": [{
              "type": "tool_result",
              "tool_use_id": "\#(toolUseId)",
              "content": "\#(resultText)",
              "is_error": \#(isError)
            }]
          }
        }
        """#
    }

    @Test("Synthetic-fallback tool_result followed by real tool_use → single slot under skeleton")
    func toolResultBeforeToolUseIdempotentSlot() throws {
        let lines = [
            // Open the turn with a text line so the skeleton exists.
            makeAssistantTextLine(uuid: "a1", parentUuid: "u1", text: "Working"),
            // tool_result arrives first (no prior tool_use) → synthetic.
            makeToolResultLine(
                uuid: "u2", parentUuid: "a1", toolUseId: "t1",
                resultText: "result text"
            ),
            // Real tool_use for the same id → mutates same slot.
            makeAssistantToolUseLine(
                uuid: "a2", parentUuid: "u2", toolUseId: "t1", toolName: "Read"
            ),
        ]
        let agent = try buildAgentEntry(assistantLines: lines)

        // Exactly one tool sub-entry (no duplicate slot).
        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        #expect(toolSubs.count == 1)
        #expect(toolSubs.first?.id == .fromJSONL("t1"))
    }

    @Test("Duplicate tool_use re-emission within same turn overwrites the same slot last-write-wins")
    func duplicateToolUseOverwritesSameSlot() throws {
        let lines = [
            makeAssistantToolUseLineWithInput(
                uuid: "a1", parentUuid: "u1", toolUseId: "t1",
                toolName: "Read", inputJSON: #"{"file_path": "/tmp/first.txt"}"#
            ),
            // Re-emission with different input — should overwrite, not duplicate.
            makeAssistantToolUseLineWithInput(
                uuid: "a2", parentUuid: "a1", toolUseId: "t1",
                toolName: "Read", inputJSON: #"{"file_path": "/tmp/second.txt"}"#,
                timestamp: "2026-06-05T10:00:03.000Z"
            ),
        ]
        let agent = try buildAgentEntry(assistantLines: lines)

        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        #expect(toolSubs.count == 1)
        #expect(toolSubs.first?.id == .fromJSONL("t1"))
        // The second emission's input should be the one preserved (last-write-wins).
        #expect(toolSubs.first?.inputFilePath == "/tmp/second.txt")
    }

    @Test("Cross-turn tool_use_id reuse: prior turn's slot is not mutated")
    func crossTurnIdReuseDoesNotMutatePriorTurn() throws {
        // First turn: assistant with tool t1 + result.
        // Second turn: a *new* tool_result for the same id "t1" arriving
        // without a prior tool_use in this turn. Must fall through to
        // synthetic in the new turn — NOT mutate the prior turn's slot.
        let userJSON = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-05T10:00:00.000Z",
          "message": {"role": "user", "content": "go"}
        }
        """#
        let user2JSON = #"""
        {
          "type": "user",
          "uuid": "u2",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:10.000Z",
          "message": {"role": "user", "content": "again"}
        }
        """#
        let lines = [
            makeAssistantToolUseLine(uuid: "a1", parentUuid: "u1", toolUseId: "t1", toolName: "Read"),
            makeToolResultLine(
                uuid: "ur1", parentUuid: "a1", toolUseId: "t1",
                resultText: "first turn result",
                timestamp: "2026-06-05T10:00:02.000Z"
            ),
        ]
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(userJSON))
        for line in lines {
            try builder.ingest(decodeLine(line))
        }
        // Second turn — start a new user prompt + a "synthetic"
        // tool_result for the same id "t1" but in this new turn.
        try builder.ingest(decodeLine(user2JSON))
        // Open turn with a text line so a skeleton exists for the result.
        try builder.ingest(decodeLine(makeAssistantTextLine(
            uuid: "a2", parentUuid: "u2", text: "second turn",
            timestamp: "2026-06-05T10:00:11.000Z"
        )))
        try builder.ingest(decodeLine(makeToolResultLine(
            uuid: "ur2", parentUuid: "a2", toolUseId: "t1",
            resultText: "second turn synthetic",
            timestamp: "2026-06-05T10:00:12.000Z"
        )))

        let entries = builder.transcript()
        let agents = entries.compactMap { entry -> AgentEntry? in
            if case .agent(let a) = entry { return a }
            return nil
        }
        #expect(agents.count == 2)

        // First turn has its tool with the original result.
        let firstTurn = agents[0]
        let firstTools = firstTurn.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        #expect(firstTools.count == 1)
        #expect(firstTools.first?.toolName == "Read")

        // Second turn has a *new* synthetic-from-tool_result slot.
        // Crucially the first turn's tool was NOT mutated by the
        // second turn's tool_result.
        let secondTurn = agents[1]
        let secondTools = secondTurn.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        #expect(secondTools.count == 1)
        #expect(secondTools.first?.toolName == "(tool result)")
    }
}
