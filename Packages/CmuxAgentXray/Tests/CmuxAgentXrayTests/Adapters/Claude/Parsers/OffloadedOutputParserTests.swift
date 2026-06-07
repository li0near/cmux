import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase C: Claude Code's `<persisted-output>` wrapper detection. CC
/// offloads tool outputs above a size threshold to disk and inlines a
/// stub like:
/// ```
/// <persisted-output>
/// Output too large (29.3KB). Full output saved to: <abs-path>.txt
///
/// Preview (first 2KB):
/// <preview>
/// </persisted-output>
/// ```
/// Before this phase, the panel rendered the stub verbatim. The fix
/// detects the wrapper, parses (path, sizeLabel, preview), and emits a
/// `Section.offloadedOutput(...)` so the renderer surfaces an
/// "↗ Open offloaded result · 29.3KB" link.
///
/// Two-commit regression pattern: this test file lands in commit C.1
/// asserting the parser produces `.offloadedOutput`. Without the
/// parser, the builder emits a plain `.text` section with the wrapper
/// string — tests fail. Commit C.2 adds the parser and the tests pass.
@Suite("OffloadedOutputParser — <persisted-output> wrapper")
struct OffloadedOutputParserTests {

    private func decodeJSON(_ s: String) throws -> ClaudeJSONValue {
        try AgentXrayJSON.decoder.decode(ClaudeJSONValue.self, from: Data(s.utf8))
    }

    private func makeWrapperContent(
        size: String,
        path: String,
        preview: String? = "first 2KB of the file content here",
        closeTag: Bool = true
    ) -> String {
        var body = """
        <persisted-output>
        Output too large (\(size)). Full output saved to: \(path)
        """
        if let preview {
            body += "\n\nPreview (first 2KB):\n\(preview)"
        }
        if closeTag {
            body += "\n</persisted-output>"
        }
        return body
    }

    private func wrappedToolResult(_ wrapperBody: String) throws -> ClaudeJSONValue {
        // Tool results in the corpus appear as either a plain string
        // OR an array `[{"type":"text","text":"<wrapper>"}]`. Test both
        // shapes by alternating in the parameterized tests; here pick
        // the string form for simplicity.
        let escaped = wrapperBody.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return try decodeJSON("\"\(escaped)\"")
    }

    @Test("wrapper with close tag produces .offloadedOutput section")
    func wrapperWithCloseTag() throws {
        let wrapper = makeWrapperContent(size: "29.3KB", path: "/tmp/<redacted>/b1abc.txt")
        let value = try wrappedToolResult(wrapper)
        let sections = ToolResultParser.parse(value, isError: false)
        #expect(sections.count == 1, "got \(sections.count) sections")
        guard case .offloadedOutput(let off) = sections.first else {
            Issue.record("Expected .offloadedOutput, got \(sections)")
            return
        }
        #expect(off.path == "/tmp/<redacted>/b1abc.txt")
        #expect(off.sizeLabel == "29.3KB")
        #expect(off.preview?.contains("first 2KB of the file content") == true)
    }

    @Test("wrapper with truncated tail (no close tag) still parses (~21 corpus cases)")
    func wrapperTruncatedTail() throws {
        let wrapper = makeWrapperContent(size: "1.2MB", path: "/tmp/<redacted>/big.txt", closeTag: false)
        let value = try wrappedToolResult(wrapper)
        let sections = ToolResultParser.parse(value, isError: false)
        guard case .offloadedOutput(let off) = sections.first else {
            Issue.record("Expected .offloadedOutput for truncated tail, got \(sections)")
            return
        }
        #expect(off.path == "/tmp/<redacted>/big.txt")
        #expect(off.sizeLabel == "1.2MB")
    }

    @Test("wrapper with KB and MB sizes both parse")
    func wrapperSizeUnits() throws {
        for size in ["5KB", "29.3KB", "1.2MB", "100MB"] {
            let wrapper = makeWrapperContent(size: size, path: "/tmp/<redacted>/x.txt")
            let value = try wrappedToolResult(wrapper)
            let sections = ToolResultParser.parse(value, isError: false)
            guard case .offloadedOutput(let off) = sections.first else {
                Issue.record("Expected .offloadedOutput for size=\(size)")
                continue
            }
            #expect(off.sizeLabel == size, "size=\(size)")
        }
    }

    @Test("wrapper with .json file path parses")
    func wrapperJsonPath() throws {
        let wrapper = makeWrapperContent(size: "10KB", path: "/tmp/<redacted>/payload.json")
        let value = try wrappedToolResult(wrapper)
        let sections = ToolResultParser.parse(value, isError: false)
        guard case .offloadedOutput(let off) = sections.first else {
            Issue.record("Expected .offloadedOutput")
            return
        }
        #expect(off.path == "/tmp/<redacted>/payload.json")
    }

    @Test("non-wrapper text passes through unchanged")
    func nonWrapperPassthrough() throws {
        let value = try decodeJSON(#""ordinary tool output, no wrapper""#)
        let sections = ToolResultParser.parse(value, isError: false)
        guard case .text(let blocks, _) = sections.first else {
            Issue.record("Expected .text passthrough, got \(sections)")
            return
        }
        #expect(blocks == ["ordinary tool output, no wrapper"])
    }

    @Test("wrapper with malformed size+path falls through to plain text (defensive)")
    func wrapperMalformedFallthrough() throws {
        let value = try decodeJSON(#""<persisted-output>\noops, no canonical Output too large line\n</persisted-output>""#)
        let sections = ToolResultParser.parse(value, isError: false)
        // Defensive: when we see the open tag but can't extract a path,
        // keep the original text so the user still has a debuggable
        // signal in the UI.
        guard case .text = sections.first else {
            Issue.record("Expected .text fallback for malformed wrapper, got \(sections)")
            return
        }
    }

    @Test("wrapper inside text block (tool_result.content array) is also detected")
    func wrapperInArrayTextBlock() throws {
        let wrapper = makeWrapperContent(size: "200KB", path: "/tmp/<redacted>/o.txt")
        let escaped = wrapper.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let value = try decodeJSON("[{\"type\":\"text\",\"text\":\"\(escaped)\"}]")
        let sections = ToolResultParser.parse(value, isError: false)
        guard case .offloadedOutput(let off) = sections.first else {
            Issue.record("Expected .offloadedOutput from array-text-block wrapper, got \(sections)")
            return
        }
        #expect(off.sizeLabel == "200KB")
    }
}
