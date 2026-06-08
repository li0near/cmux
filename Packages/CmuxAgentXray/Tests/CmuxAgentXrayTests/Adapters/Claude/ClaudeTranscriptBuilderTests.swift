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
        // Post-G6: this scenario (tool_result line whose `tool_use_id`
        // has no prior tool_use in the same turn) silently drops the
        // result and the subsequent real `tool_use` creates the slot
        // fresh. The test verifies the resulting transcript has one
        // tool sub-entry with the expected id (no duplication, no
        // dangling synthetic). The pool path covers genuine
        // parallel-tool-call out-of-order in real corpus; this
        // fixture tests the defensive shape where the synthetic
        // fallback is no longer needed.
        let lines = [
            makeAssistantTextLine(uuid: "a1", parentUuid: "u1", text: "Working"),
            makeToolResultLine(
                uuid: "u2", parentUuid: "a1", toolUseId: "t1",
                resultText: "result text"
            ),
            makeAssistantToolUseLine(
                uuid: "a2", parentUuid: "u2", toolUseId: "t1", toolName: "Read"
            ),
        ]
        let agent = try buildAgentEntry(assistantLines: lines)

        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        #expect(toolSubs.count == 1)
        #expect(toolSubs.first?.id == .fromJSONL("t1"))
    }

    // MARK: - G6 coverage

    @Test("Out-of-order: tool_result line arriving before its tool_use lands via awaitingParent pool")
    func outOfOrderToolResultPoolDrain() throws {
        // tool_result line (`ur1`) parented to a tool_use line `a-tool`
        // that arrives LATER in the file. The dispatcher must park
        // `ur1` in the awaitingParent pool keyed on `a-tool` and
        // re-dispatch it once `a-tool` is processed, mutating the
        // ToolEntry with the tool_result.
        let textLine = makeAssistantTextLine(uuid: "a1", parentUuid: "u1", text: "Working")
        let toolResultLine = makeToolResultLine(
            uuid: "ur1", parentUuid: "a-tool", toolUseId: "t1",
            resultText: "expected result text",
            timestamp: "2026-06-05T10:00:03.000Z"
        )
        let toolUseLine = makeAssistantToolUseLine(
            uuid: "a-tool", parentUuid: "a1", toolUseId: "t1", toolName: "Read",
            timestamp: "2026-06-05T10:00:02.000Z"
        )
        let agent = try buildAgentEntry(assistantLines: [
            textLine, toolResultLine, toolUseLine,
        ])

        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        #expect(toolSubs.count == 1)
        #expect(toolSubs.first?.status == .ok)
        // Result body should contain the expected text.
        let bodyText = toolSubs.first.map { tool in
            tool.body.sections.compactMap { section -> String? in
                if case .text(let blocks, _) = section {
                    return blocks.joined(separator: "\n")
                }
                return nil
            }.joined(separator: "\n")
        } ?? ""
        #expect(bodyText.contains("expected result text"))
    }

    @Test("Rewind: user prompt re-parenting to mid-tree node folds abandoned tail into branchLink")
    func rewindFoldsAbandonedTail() throws {
        // u1 → a1 (assistant) → u-rewind whose parentUuid points back
        // at u1. The dispatcher detects rewind (u1's tail past slot 0
        // has trailing entries) and slices the tail into a synthesized
        // .branchLink at top-level slot 1.
        let userJSON = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-05T10:00:00.000Z",
          "message": {"role": "user", "content": "first"}
        }
        """#
        let rewindUserJSON = #"""
        {
          "type": "user",
          "uuid": "u-rewind",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:10.000Z",
          "message": {"role": "user", "content": "rewound"}
        }
        """#
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(userJSON))
        try builder.ingest(decodeLine(makeAssistantTextLine(
            uuid: "a1", parentUuid: "u1", text: "first response"
        )))
        try builder.ingest(decodeLine(rewindUserJSON))

        let entries = builder.transcript()
        // [u1, branchLink (with a1 nested), u-rewind]
        #expect(entries.count == 3)
        guard case .synthesized(let link) = entries[1],
              case .branchLink = link.kind else {
            Issue.record("expected branchLink at slot 1; got \(entries[1])")
            return
        }
        // The abandoned AgentEntry@a1 should be inside the link.
        #expect(link.subEntries.count == 1)
        if case .agent(let abandoned) = link.subEntries[0] {
            #expect(abandoned.id == .fromJSONL("a1"))
        } else {
            Issue.record("expected abandoned .agent inside branchLink")
        }
        // The new prompt is at slot 2.
        if case .user(let userEntry) = entries[2] {
            #expect(userEntry.id == .fromJSONL("u-rewind"))
        } else {
            Issue.record("expected new UserEntry at slot 2")
        }
    }

    @Test("Queued slash-cmd: enqueue followed by matching slash-cmd input pops FIFO and emits .consumed UserEntry")
    func queuedSlashCmdConsumesFIFO() throws {
        // Enqueue `/aicore-api`, then a slash-cmd input line for the
        // same text — should slice out the .pending UserEntry and
        // append a .consumed UserEntry. (Verified empirically in this
        // very session: queued `/aicore-api` surfaced this way.)
        let userJSON = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-05T10:00:00.000Z",
          "message": {"role": "user", "content": "go"}
        }
        """#
        let enqueueJSON = #"""
        {
          "type": "queue-operation",
          "operation": "enqueue",
          "uuid": "q1",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:01.000Z",
          "content": "/aicore-api"
        }
        """#
        // System slash-command input line carries the <command-name>
        // / <command-message> wrappers in its content.
        let slashCmdInputJSON = #"""
        {
          "type": "system",
          "subtype": "local_command",
          "uuid": "s1",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:02.000Z",
          "content": "<command-message>aicore-api</command-message>\n<command-name>aicore-api</command-name>"
        }
        """#
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(userJSON))
        try builder.ingest(decodeLine(enqueueJSON))
        try builder.ingest(decodeLine(slashCmdInputJSON))

        let entries = builder.transcript()
        let users = entries.compactMap { entry -> UserEntry? in
            if case .user(let u) = entry { return u }
            return nil
        }
        // Two users: original "go" + consumed "/aicore-api" — the
        // .pending entry between them was sliced out by FIFO pop.
        #expect(users.count == 2)
        #expect(users.first?.queuedState == UserEntry.QueuedState.none)
        #expect(users.last?.queuedState == .consumed)
    }

    @Test("Unconsumed enqueue stays as a .pending UserEntry at top-level")
    func unconsumedEnqueueRemainsPending() throws {
        // Enqueue without a matching slash-cmd or attachment.queued_command
        // → `.pending` UserEntry stays in the transcript.
        let userJSON = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-05T10:00:00.000Z",
          "message": {"role": "user", "content": "go"}
        }
        """#
        let enqueueJSON = #"""
        {
          "type": "queue-operation",
          "operation": "enqueue",
          "uuid": "q1",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:01.000Z",
          "content": "stay pending"
        }
        """#
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(userJSON))
        try builder.ingest(decodeLine(enqueueJSON))

        let entries = builder.transcript()
        let pendings = entries.compactMap { entry -> UserEntry? in
            if case .user(let u) = entry, u.queuedState == .pending { return u }
            return nil
        }
        #expect(pendings.count == 1)
    }

    @Test("turn_duration line stamps perTurnDurationMs and messageCount on the AgentEntry")
    func turnDurationStampsAgentEntry() throws {
        // Turn: u1 → a1 (text). Then a `system/turn_duration` line
        // parented to a1 with durationMs=1234, messageCount=3.
        // Expected: AgentEntry@a1 has perTurnDurationMs=1234,
        // messageCount=3.
        let lines = [
            makeAssistantTextLine(uuid: "a1", parentUuid: "u1", text: "Working"),
        ]
        let turnDurationJSON = #"""
        {
          "type": "system",
          "subtype": "turn_duration",
          "uuid": "td1",
          "parentUuid": "a1",
          "timestamp": "2026-06-05T10:00:05.000Z",
          "durationMs": 1234,
          "messageCount": 3
        }
        """#
        let userJSON = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-05T10:00:00.000Z",
          "message": {"role": "user", "content": "go"}
        }
        """#
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(userJSON))
        for line in lines {
            try builder.ingest(decodeLine(line))
        }
        try builder.ingest(decodeLine(turnDurationJSON))

        let entries = builder.transcript()
        let agent = entries.compactMap { entry -> AgentEntry? in
            if case .agent(let a) = entry { return a }
            return nil
        }.first
        #expect(agent?.perTurnDurationMs == 1234)
        #expect(agent?.messageCount == 3)
    }
}
