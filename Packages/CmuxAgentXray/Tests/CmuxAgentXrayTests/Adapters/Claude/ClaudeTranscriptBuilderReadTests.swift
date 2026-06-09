import Foundation
import Testing
@testable import CmuxAgentXray

/// Verifies that the Read tool's result body is rewritten to
/// `Section.code(.plain(text:, language:))` (with language derived
/// from `inputFilePath`'s extension) and that the
/// `OffloadedOutputParser.promote(_:)` post-pass runs BEFORE this
/// rewrite — so a Read whose result was offloaded by Claude Code
/// still surfaces as `.offloadedOutput`, not `.code(.plain)`.
@Suite("ClaudeTranscriptBuilder — Read tool .code(.plain) swap")
struct ClaudeTranscriptBuilderReadTests {

    @available(macOS 15, *)
    @Test("Read result body becomes .code(.plain) with language derived from file extension")
    func readResultBecomesCodePlain() throws {
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
              "id": "tool-read-1",
              "name": "Read",
              "input": {"file_path": "/tmp/foo.swift"}
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
              "tool_use_id": "tool-read-1",
              "content": "let x = 1\nlet y = 2"
            }]
          }
        }
        """#
        let agent = try buildAgent(assistantLines: [toolUseJSON, toolResultJSON])
        let tool = try #require(firstTool(in: agent))
        #expect(tool.toolName == "Read")
        // Body: index 0 = parser-input section (file_path summary),
        // index 1 = the result. The Read swap targets the result only.
        guard case .code(.plain(let text, let language, let lineNumberStart)) = tool.body.sections.last else {
            Issue.record("Expected .code(.plain) result section; got \(tool.body.sections)")
            return
        }
        #expect(text == "let x = 1\nlet y = 2")
        #expect(language == "swift")
        #expect(lineNumberStart == 1)
    }

    @available(macOS 15, *)
    @Test("Read result that's been offloaded stays .offloadedOutput (promote runs before code swap)")
    func readOffloadedStaysOffloaded() throws {
        // Claude Code's `<persisted-output>` wrapper is generated when
        // the tool result exceeds the inline-size threshold. The
        // builder's `OffloadedOutputParser.promote(_:)` post-pass
        // (invoked inside `ToolResultParser.parse`) swaps the .text
        // section to .offloadedOutput. The Read-shape `.code(.plain)`
        // swap that follows must only walk remaining `.text` sections;
        // the offloaded section must survive.
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
              "id": "tool-read-2",
              "name": "Read",
              "input": {"file_path": "/tmp/big.txt"}
            }]
          }
        }
        """#
        let persisted = """
        <persisted-output>
        Output too large (29.3KB). Full output saved to: /tmp/cc-offloaded.txt

        Preview (first 2KB):
        sample line 1
        sample line 2
        </persisted-output>
        """
        let escaped = persisted
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
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
              "tool_use_id": "tool-read-2",
              "content": "\#(escaped)"
            }]
          }
        }
        """#
        let agent = try buildAgent(assistantLines: [toolUseJSON, toolResultJSON])
        let tool = try #require(firstTool(in: agent))
        #expect(tool.toolName == "Read")
        // Last section must be .offloadedOutput — NOT .code(.plain)
        // (which would mean promote ran after the swap).
        guard case .offloadedOutput(let off) = tool.body.sections.last else {
            Issue.record("Expected .offloadedOutput result section; got \(tool.body.sections)")
            return
        }
        #expect(off.path == "/tmp/cc-offloaded.txt")
        #expect(off.sizeLabel == "29.3KB")
    }

    @available(macOS 15, *)
    @Test("Bash result becomes .code(.plain) with no language hint and no gutter")
    func bashResultBecomesCodePlain() throws {
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
        let agent = try buildAgent(assistantLines: [toolUseJSON, toolResultJSON])
        let tool = try #require(firstTool(in: agent))
        #expect(tool.toolName == "Bash")
        // Bash body has the input section + result section; the
        // result is `.code(.plain(_, language: nil, lineNumberStart: nil))`.
        guard case .code(.plain(let text, let language, let lineNumberStart)) = tool.body.sections.last else {
            Issue.record("Expected .code(.plain) result section for Bash; got \(tool.body.sections)")
            return
        }
        #expect(text == "hi")
        #expect(language == nil)
        #expect(lineNumberStart == nil)
    }

    // MARK: - Helpers

    private func buildAgent(assistantLines: [String]) throws -> AgentEntry {
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
        try builder.ingest(decode(userJSON))
        for line in assistantLines {
            try builder.ingest(decode(line))
        }
        let entries = builder.transcript()
        for entry in entries {
            if case .agent(let agent) = entry {
                return agent
            }
        }
        Issue.record("No AgentEntry in transcript")
        return AgentEntry(
            id: .fromJSONL("missing"),
            header: Header(),
            body: .empty,
            usage: .zero
        )
    }

    private func firstTool(in agent: AgentEntry) -> ToolEntry? {
        for entry in agent.subEntries {
            if case .tool(let t) = entry { return t }
        }
        return nil
    }

    private func decode(_ json: String) throws -> ClaudeJSONLLine {
        let data = json.data(using: .utf8)!
        return try AgentXrayJSON.decoder.decode(ClaudeJSONLLine.self, from: data)
    }
}
