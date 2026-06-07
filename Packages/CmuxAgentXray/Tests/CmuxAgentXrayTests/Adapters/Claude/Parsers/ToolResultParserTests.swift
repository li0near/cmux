import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase B.2: ``ClaudeTranscriptBuilder/buildToolResultSections(_:isError:)``
/// rewrite. Replaces the legacy `flattenToolResult(_:)` which join-flattened
/// every block into one string and silently dropped images / `tool_reference`
/// blocks. The new function emits one ``Section`` per
/// `tool_result.content[]` block in JSONL arrival order.
@Suite("ToolResultParser — per-block emission")
struct ToolResultParserTests {

    private func decodeJSON(_ s: String) throws -> ClaudeJSONValue {
        try AgentXrayJSON.decoder.decode(ClaudeJSONValue.self, from: Data(s.utf8))
    }

    @Test("nil → empty array")
    func nilProducesEmpty() {
        let sections = ToolResultParser.parse(nil, isError: false)
        #expect(sections.isEmpty)
    }

    @Test("string-shaped content (legacy single-string) → one .text section")
    func stringContent() throws {
        let value = try decodeJSON(#""hello world""#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 1)
        if case .text(let blocks, let style) = sections[0] {
            #expect(blocks == ["hello world"])
            #expect(style == .normal)
        } else {
            Issue.record("Expected .text section, got \(sections[0])")
        }
    }

    @Test("string-shaped error content carries .error TextStyle")
    func stringErrorStyle() throws {
        let value = try decodeJSON(#""boom""#)
        let sections = ToolResultParser.parse(value, isError: true)
        if case .text(_, let style) = sections[0] {
            #expect(style == .error)
        } else {
            Issue.record("Expected .text section")
        }
    }

    @Test("text block in array → one .text section")
    func textBlock() throws {
        let value = try decodeJSON(#"""
        [{"type":"text","text":"hi"}]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 1)
        if case .text(let blocks, _) = sections[0] {
            #expect(blocks == ["hi"])
        } else {
            Issue.record("Expected .text")
        }
    }

    @Test("base64 image block → .image section")
    func imageBlock() throws {
        let value = try decodeJSON(#"""
        [{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 1)
        if case .image(let source) = sections[0] {
            #expect(source.kind == .base64)
            #expect(source.mediaType == "image/png")
            #expect(source.data == "iVBORw0KGgo=")
        } else {
            Issue.record("Expected .image, got \(sections[0])")
        }
    }

    @Test("tool_reference block → .toolReference section")
    func toolReferenceBlock() throws {
        let value = try decodeJSON(#"""
        [{"type":"tool_reference","tool_name":"mcp__sap-jira__get_issue"}]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 1)
        if case .toolReference(let name) = sections[0] {
            #expect(name == "mcp__sap-jira__get_issue")
        } else {
            Issue.record("Expected .toolReference")
        }
    }

    @Test("Playwright pair (text + image) emits two sections in JSONL arrival order")
    func playwrightTextImagePair() throws {
        let value = try decodeJSON(#"""
        [
          {"type":"text","text":"Took a screenshot."},
          {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0K"}}
        ]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 2)
        guard case .text = sections[0], case .image = sections[1] else {
            Issue.record("Expected [.text, .image], got \(sections)")
            return
        }
    }

    @Test("redacted_thinking / search_result / document → text stub placeholder")
    func specOnlyStubs() throws {
        for type in ["redacted_thinking", "search_result", "document"] {
            let value = try decodeJSON(#"""
            [{"type":"\#(type)"}]
            """#)
            let sections = ToolResultParser.parse(value, isError: false)
            #expect(sections.count == 1, "type=\(type)")
            if case .text(let blocks, _) = sections[0] {
                #expect(blocks == ["[\(type)]"], "type=\(type)")
            } else {
                Issue.record("Expected .text stub for \(type)")
            }
        }
    }

    @Test("unknown block type → text stub with type label")
    func unknownStub() throws {
        let value = try decodeJSON(#"""
        [{"type":"audio_widget"}]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 1)
        if case .text(let blocks, _) = sections[0] {
            #expect(blocks == ["[audio_widget]"])
        } else {
            Issue.record("Expected .text stub for unknown type")
        }
    }

    @Test("Malformed image block (missing source.data) drops to nil")
    func malformedImageDropped() throws {
        let value = try decodeJSON(#"""
        [{"type":"image","source":{"type":"base64","media_type":"image/png"}}]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        // compactMap drops the malformed block; no other blocks present.
        #expect(sections.isEmpty)
    }

    @Test("URL-mode image (spec but not in corpus) drops to nil")
    func urlModeImageDropped() throws {
        let value = try decodeJSON(#"""
        [{"type":"image","source":{"type":"url","url":"https://example.com/x.png"}}]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        // Phase B treats URL-mode as unsupported (defer until corpus shows it).
        #expect(sections.isEmpty)
    }

    @Test("Mixed block types preserve arrival order")
    func mixedOrdering() throws {
        let value = try decodeJSON(#"""
        [
          {"type":"text","text":"intro"},
          {"type":"tool_reference","tool_name":"mcp__sap-jira__get_issue"},
          {"type":"text","text":"outro"}
        ]
        """#)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 3)
        guard case .text(let intro, _) = sections[0],
              case .toolReference(let name) = sections[1],
              case .text(let outro, _) = sections[2] else {
            Issue.record("Wrong ordering: \(sections)")
            return
        }
        #expect(intro == ["intro"])
        #expect(name == "mcp__sap-jira__get_issue")
        #expect(outro == ["outro"])
    }
}
