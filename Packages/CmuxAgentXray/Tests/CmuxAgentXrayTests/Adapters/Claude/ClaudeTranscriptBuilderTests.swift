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
}
