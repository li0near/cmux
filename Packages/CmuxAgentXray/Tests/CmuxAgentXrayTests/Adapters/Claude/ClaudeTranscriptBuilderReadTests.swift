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
    @Test("Read result body parses Claude Code's <num>\\t<text> shape: strips numbers, captures offset")
    func readResultStripsLineNumbers() throws {
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
              "input": {"file_path": "/tmp/foo.swift", "offset": 10, "limit": 2}
            }]
          }
        }
        """#
        // Claude Code's Read tool output: padded line number + tab +
        // line text. Two lines: "10\tlet x = 1" and "11\tlet y = 2".
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
              "content": "    10\tlet x = 1\n    11\tlet y = 2"
            }]
          }
        }
        """#
        let agent = try buildAgent(assistantLines: [toolUseJSON, toolResultJSON])
        let tool = try #require(firstTool(in: agent))
        guard case .code(.plain(let text, let language, let lineNumberStart)) = tool.body.sections.last else {
            Issue.record("Expected .code(.plain) result section; got \(tool.body.sections)")
            return
        }
        // Numbers stripped; offset captured as 10.
        #expect(text == "let x = 1\nlet y = 2")
        #expect(language == "swift")
        #expect(lineNumberStart == 10)
    }

    @available(macOS 15, *)
    @Test("Read status envelope ('File does not exist') stays .text — parser miss falls back, no .code swap")
    func readStatusEnvelopeStaysText() throws {
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
              "input": {"file_path": "/tmp/missing.txt"}
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
              "content": "File does not exist. Note: your current working directory is /tmp"
            }]
          }
        }
        """#
        let agent = try buildAgent(assistantLines: [toolUseJSON, toolResultJSON])
        let tool = try #require(firstTool(in: agent))
        guard case .text(let blocks, _) = tool.body.sections.last else {
            Issue.record("Expected .text fallback for status envelope; got \(tool.body.sections)")
            return
        }
        #expect(blocks.joined().contains("File does not exist"))
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
    @Test("Bash result stays .text (Read swap doesn't touch other tools)")
    func bashResultStaysText() throws {
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
        // Bash body has the input section + result text section; the
        // result must remain .text (sectionIndex 1).
        let last = tool.body.sections.last
        guard case .text = last else {
            Issue.record("Expected .text result for Bash; got \(String(describing: last))")
            return
        }
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
