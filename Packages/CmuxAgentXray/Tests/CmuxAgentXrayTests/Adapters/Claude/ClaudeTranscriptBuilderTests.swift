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

    // MARK: - Tool-result + queued-prompt + rewind fixtures

    /// Helper: a user line bearing a tool_result block. Routed by the
    /// builder's `classifyUserLine` to the agent path so it folds
    /// into the resolved AgentEntry as a tool_result mutation.
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

    @Test("Tool result for tool_use_id with no matching tool_use is silently dropped; later real tool_use creates pending slot")
    func toolResultBeforeToolUseIdempotentSlot() throws {
        // Post-G6: the orphan `tool_result` line whose `tool_use_id`
        // has no prior `tool_use` in the same turn is silently dropped
        // (logger.warning). The subsequent real `tool_use` creates a
        // fresh `.pending` slot. Verifies: one tool entry with the
        // expected id AND status == .pending — proving the orphan
        // result body was NOT applied. (Pool path covers genuine
        // parallel-tool-call out-of-order; this fixture tests the
        // defensive-orphan shape.)
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
        let tool = try #require(toolSubs.first)
        #expect(toolSubs.count == 1)
        #expect(tool.id == .fromJSONL("t1"))
        // The orphan tool_result was dropped, NOT applied — slot is pending.
        #expect(tool.status == .pending)
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
        let tool = try #require(toolSubs.first)
        #expect(toolSubs.count == 1)
        #expect(tool.status == .ok)
        // Body has [input section, result section] — the result
        // section's text is exactly the parsed result body.
        let resultSection = tool.body.sections.last
        guard case .text(let blocks, _) = resultSection else {
            Issue.record("expected .text result section, got \(String(describing: resultSection))")
            return
        }
        #expect(blocks.joined(separator: "\n") == "expected result text")
    }

    @Test("Rewind: user prompt re-parenting to mid-tree node folds abandoned tail into rewind")
    func rewindFoldsAbandonedTail() throws {
        // u1 → a1 (assistant) → u-rewind whose parentUuid points back
        // at u1. The dispatcher detects rewind (u1's tail past slot 0
        // has trailing entries) and slices the tail into a synthesized
        // .rewind at top-level slot 1.
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(JSONLFixture.line(named: "builder-user-first"))
        try builder.ingest(decodeLine(makeAssistantTextLine(
            uuid: "a1", parentUuid: "u1", text: "first response"
        )))
        try builder.ingest(JSONLFixture.line(named: "builder-user-rewind"))

        let entries = builder.transcript()
        // [u1, rewind (with a1 nested), u-rewind]
        #expect(entries.count == 3)
        guard case .synthesized(let link) = entries[1],
              case .rewind = link.kind else {
            Issue.record("expected rewind at slot 1; got \(entries[1])")
            return
        }
        // The abandoned AgentEntry@a1 should be inside the link.
        #expect(link.subEntries.count == 1)
        // Header carries the new "Abandoned Branch" name + a count
        // label that matches subEntries.count.
        #expect(link.header.name == "Abandoned Branch")
        #expect(link.header.label == "1 entries")
        guard case .agent(let abandoned) = link.subEntries[0] else {
            Issue.record("expected abandoned .agent inside rewind; got \(link.subEntries[0])")
            return
        }
        #expect(abandoned.id == .fromJSONL("a1"))
        // The new prompt is at slot 2.
        guard case .user(let userEntry) = entries[2] else {
            Issue.record("expected new UserEntry at slot 2; got \(entries[2])")
            return
        }
        #expect(userEntry.id == .fromJSONL("u-rewind"))
    }

    @Test("Queued slash-cmd: enqueue followed by matching slash-cmd input pops FIFO and emits .consumed UserEntry")
    func queuedSlashCmdConsumesFIFO() throws {
        // Enqueue `/aicore-api`, then a slash-cmd input line for the
        // same text — should slice out the .pending UserEntry and
        // append a .consumed UserEntry. (Verified empirically in this
        // very session: queued `/aicore-api` surfaced this way.)
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(JSONLFixture.line(named: "builder-user-go"))
        try builder.ingest(JSONLFixture.line(named: "builder-queue-enqueue-aicore-api"))
        try builder.ingest(JSONLFixture.line(named: "builder-slash-cmd-input-aicore-api"))

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
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(JSONLFixture.line(named: "builder-user-go"))
        try builder.ingest(JSONLFixture.line(named: "builder-queue-enqueue-stay-pending"))

        let entries = builder.transcript()
        let pendings = entries.compactMap { entry -> UserEntry? in
            if case .user(let u) = entry, u.queuedState == .pending { return u }
            return nil
        }
        let pending = try #require(pendings.first)
        #expect(pendings.count == 1)
        #expect(pending.body.textContent == "stay pending")
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
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(JSONLFixture.line(named: "builder-user-go"))
        for line in lines {
            try builder.ingest(decodeLine(line))
        }
        try builder.ingest(JSONLFixture.line(named: "builder-turn-duration"))

        let entries = builder.transcript()
        let agent = entries.compactMap { entry -> AgentEntry? in
            if case .agent(let a) = entry { return a }
            return nil
        }.first
        #expect(agent?.perTurnDurationMs == 1234)
        #expect(agent?.messageCount == 3)
    }

    @Test("Skipped attachment with null parentUuid still aliases — children chaining off it don't pool forever")
    func skippedOrphanAttachmentDoesNotBlockDescendants() throws {        // Real-corpus shape (verified 2026-06-09 in this very session):
        // line 0 is an `attachment/hook_success` with parentUuid=null.
        // hook_success is not in AttachmentLineDispatcher's render set,
        // so it routes to .skip. Without aliasing the orphan to []
        // path, every descendant (the user prompt that follows, plus
        // its entire turn chain) blocks in awaitingParent and the
        // transcript renders empty.
        var builder = ClaudeTranscriptBuilder()
        for line in try JSONLFixture.lines(named: "builder-skipped-attachment-orphan") {
            try builder.ingest(line)
        }

        let entries = builder.transcript()
        // [user, agent] — the hook_success attachment is skipped (no
        // entry produced) but its alias unblocks the user + agent
        // descendants.
        let userEntries = entries.compactMap { entry -> UserEntry? in
            if case .user(let u) = entry { return u }
            return nil
        }
        let agentEntries = entries.compactMap { entry -> AgentEntry? in
            if case .agent(let a) = entry { return a }
            return nil
        }
        #expect(userEntries.count == 1)
        #expect(agentEntries.count == 1)
        #expect(agentEntries.first?.subEntries.count == 1)
    }

    // MARK: - Phase H: structuredPatch → Section.diffHunks

    @Test("Edit tool with structuredPatch result emits a single .diffHunks section; input section is suppressed")
    func editStructuredPatchEmitsDiffHunksSection() throws {
        // Edit tool_use (input untouched) followed by a tool_result
        // line carrying `toolUseResult.structuredPatch`. Builder must
        // produce a ToolEntry whose body is exactly [.diffHunks([Hunk])]
        // (no leading input section — Edit's input is rendered via
        // the diff hunks themselves) and whose status is .ok.
        let toolUseJSON = #"""
        {
          "type": "assistant",
          "uuid": "a1",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:01.000Z",
          "message": {
            "role": "assistant",
            "content": [{
              "type": "tool_use",
              "id": "tool-edit-1",
              "name": "Edit",
              "input": {
                "file_path": "/tmp/foo.swift",
                "old_string": "let x = 1",
                "new_string": "let x = 2"
              }
            }]
          }
        }
        """#
        let toolResultJSON = #"""
        {
          "type": "user",
          "uuid": "u2",
          "parentUuid": "a1",
          "timestamp": "2026-06-05T10:00:02.000Z",
          "message": {
            "role": "user",
            "content": [{
              "type": "tool_result",
              "tool_use_id": "tool-edit-1",
              "content": "The file /tmp/foo.swift has been updated successfully."
            }]
          },
          "toolUseResult": {
            "filePath": "/tmp/foo.swift",
            "oldString": "let x = 1",
            "newString": "let x = 2",
            "structuredPatch": [{
              "oldStart": 1,
              "oldLines": 1,
              "newStart": 1,
              "newLines": 1,
              "lines": ["-let x = 1", "+let x = 2"]
            }]
          }
        }
        """#
        let agent = try buildAgentEntry(assistantLines: [toolUseJSON, toolResultJSON])
        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        let tool = try #require(toolSubs.first)
        #expect(tool.status == .ok)
        // Body has exactly one section: the diff hunks.
        #expect(tool.body.sections.count == 1)
        guard case .code(.diff(let hunks)) = tool.body.sections.first else {
            Issue.record("Expected .code(.diff) section; got \(tool.body.sections)")
            return
        }
        #expect(hunks.count == 1)
        let hunk = try #require(hunks.first)
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldLines == 1)
        #expect(hunk.newStart == 1)
        #expect(hunk.newLines == 1)
        #expect(hunk.lines == ["-let x = 1", "+let x = 2"])
    }

    @Test("Write tool with type=create (empty structuredPatch) keeps the parser-produced result section")
    func writeCreateKeepsParserOutput() throws {
        let toolUseJSON = #"""
        {
          "type": "assistant",
          "uuid": "a1",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:01.000Z",
          "message": {
            "role": "assistant",
            "content": [{
              "type": "tool_use",
              "id": "tool-write-1",
              "name": "Write",
              "input": {
                "file_path": "/tmp/new.txt",
                "content": "hello world"
              }
            }]
          }
        }
        """#
        let toolResultJSON = #"""
        {
          "type": "user",
          "uuid": "u2",
          "parentUuid": "a1",
          "timestamp": "2026-06-05T10:00:02.000Z",
          "message": {
            "role": "user",
            "content": [{
              "type": "tool_result",
              "tool_use_id": "tool-write-1",
              "content": "File created successfully at: /tmp/new.txt"
            }]
          },
          "toolUseResult": {
            "type": "create",
            "filePath": "/tmp/new.txt",
            "content": "hello world",
            "structuredPatch": []
          }
        }
        """#
        let agent = try buildAgentEntry(assistantLines: [toolUseJSON, toolResultJSON])
        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        let tool = try #require(toolSubs.first)
        #expect(tool.status == .ok)
        // Empty structuredPatch → falls through to parser-produced
        // result section. No input section for Write either (Write
        // is Edit-shape per `isEditShape`); body has only the parser
        // result. Real Write-create result is "File created
        // successfully" plain text → one .text section.
        #expect(tool.body.sections.count == 1)
        guard case .text = tool.body.sections.first else {
            Issue.record("Expected .text result section for Write-create; got \(tool.body.sections)")
            return
        }
    }

    @Test("Non-Edit tool keeps input section and parser result section")
    func nonEditToolKeepsBothSections() throws {
        let toolUseJSON = #"""
        {
          "type": "assistant",
          "uuid": "a1",
          "parentUuid": "u1",
          "timestamp": "2026-06-05T10:00:01.000Z",
          "message": {
            "role": "assistant",
            "content": [{
              "type": "tool_use",
              "id": "tool-bash-1",
              "name": "Bash",
              "input": {"command": "echo hi"}
            }]
          }
        }
        """#
        let toolResultJSON = #"""
        {
          "type": "user",
          "uuid": "u2",
          "parentUuid": "a1",
          "timestamp": "2026-06-05T10:00:02.000Z",
          "message": {
            "role": "user",
            "content": [{
              "type": "tool_result",
              "tool_use_id": "tool-bash-1",
              "content": "hi"
            }]
          }
        }
        """#
        let agent = try buildAgentEntry(assistantLines: [toolUseJSON, toolResultJSON])
        let toolSubs = agent.subEntries.compactMap { entry -> ToolEntry? in
            if case .tool(let t) = entry { return t }
            return nil
        }
        let tool = try #require(toolSubs.first)
        // Body: [input .text, result .text].
        #expect(tool.body.sections.count == 2)
        guard case .text = tool.body.sections[0],
              case .text = tool.body.sections[1] else {
            Issue.record("Expected [.text, .text] for non-Edit tool; got \(tool.body.sections)")
            return
        }
    }
}
