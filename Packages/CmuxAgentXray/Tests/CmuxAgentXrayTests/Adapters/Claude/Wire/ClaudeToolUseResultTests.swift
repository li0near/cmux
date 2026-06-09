import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase H1: typed envelope projection from the polymorphic
/// `toolUseResult` JSONL field. Edit / MultiEdit / Write-update emit an
/// object payload with `structuredPatch` etc.; Bash errors emit a bare
/// String; Playwright-style tool results emit a JSON array of text
/// blocks. Modeling `ClaudeJSONLLine.toolUseResult` as the polymorphic
/// `ClaudeJSONValue?` keeps decode green for all three; the typed
/// `ClaudeToolUseResult.from(_:)` factory returns nil for the
/// non-object shapes so callers fall through to the standard
/// `tool_result.content` path.
@Suite("ClaudeToolUseResult — typed envelope projection")
struct ClaudeToolUseResultTests {

    @Test("Edit object decodes and projects with structured patch")
    func editObjectProjects() throws {
        let line = try JSONLFixture.line(named: "tool-use-result-edit-with-patch")
        let payload = try #require(ClaudeToolUseResult.from(line.toolUseResult))
        #expect(payload.filePath?.hasSuffix(".rs") == true)
        #expect(payload.oldString != nil)
        #expect(payload.newString != nil)
        #expect(payload.originalFile != nil)
        #expect(payload.structuredPatch?.count == 1)
        let hunk = try #require(payload.structuredPatch?.first)
        #expect(hunk.lines.count >= 1)
        // Every line in the corpus starts with one of the three diff
        // prefixes; verify the wire shape is preserved verbatim.
        for line in hunk.lines {
            let first = line.first
            #expect(first == " " || first == "-" || first == "+",
                   "Unexpected prefix on line: \(line)")
        }
    }

    @Test("Write update object decodes with non-empty structured patch and type=update")
    func writeUpdateProjects() throws {
        let line = try JSONLFixture.line(named: "tool-use-result-write-update")
        let payload = try #require(ClaudeToolUseResult.from(line.toolUseResult))
        #expect(payload.type == "update")
        #expect(payload.structuredPatch?.isEmpty == false)
    }

    @Test("Write create object decodes with empty structured patch and type=create")
    func writeCreateProjects() throws {
        let line = try JSONLFixture.line(named: "tool-use-result-write-create")
        let payload = try #require(ClaudeToolUseResult.from(line.toolUseResult))
        #expect(payload.type == "create")
        #expect(payload.structuredPatch?.isEmpty == true)
    }

    @Test("Bash error string toolUseResult — line decodes; projection returns nil")
    func bashErrorStringProjectsNil() throws {
        let line = try JSONLFixture.line(named: "tool-use-result-bash-error-string")
        // The whole-line decode survived (this is the polymorphic-decode
        // hazard the wire-side ClaudeJSONValue? guards against).
        if case .string = line.toolUseResult {
            // expected
        } else {
            Issue.record("Expected .string toolUseResult; got \(String(describing: line.toolUseResult))")
        }
        // Projection rejects non-object shape.
        #expect(ClaudeToolUseResult.from(line.toolUseResult) == nil)
    }

    @Test("Playwright text-block list toolUseResult — line decodes; projection returns nil")
    func playwrightListProjectsNil() throws {
        let line = try JSONLFixture.line(named: "tool-use-result-playwright-list")
        if case .array = line.toolUseResult {
            // expected
        } else {
            Issue.record("Expected .array toolUseResult; got \(String(describing: line.toolUseResult))")
        }
        #expect(ClaudeToolUseResult.from(line.toolUseResult) == nil)
    }

    @Test("Nil toolUseResult projects nil")
    func nilProjectsNil() {
        #expect(ClaudeToolUseResult.from(nil) == nil)
    }

    @Test("Hand-constructed object via ClaudeJSONValue projects every field")
    func handConstructedFullObject() {
        let value: ClaudeJSONValue = .object([
            "filePath": .string("/tmp/x.swift"),
            "oldString": .string("old"),
            "newString": .string("new"),
            "originalFile": .string("file content"),
            "userModified": .bool(true),
            "replaceAll": .bool(false),
            "type": .string("update"),
            "structuredPatch": .array([
                .object([
                    "oldStart": .int(10),
                    "oldLines": .int(2),
                    "newStart": .int(10),
                    "newLines": .int(3),
                    "lines": .array([
                        .string(" ctx"),
                        .string("-old"),
                        .string("+new1"),
                        .string("+new2")
                    ])
                ])
            ])
        ])
        let payload = ClaudeToolUseResult.from(value)
        #expect(payload?.filePath == "/tmp/x.swift")
        #expect(payload?.oldString == "old")
        #expect(payload?.newString == "new")
        #expect(payload?.originalFile == "file content")
        #expect(payload?.userModified == true)
        #expect(payload?.replaceAll == false)
        #expect(payload?.type == "update")
        let hunks = try? #require(payload?.structuredPatch)
        #expect(hunks?.count == 1)
        #expect(hunks?.first?.oldStart == 10)
        #expect(hunks?.first?.oldLines == 2)
        #expect(hunks?.first?.newStart == 10)
        #expect(hunks?.first?.newLines == 3)
        #expect(hunks?.first?.lines == [" ctx", "-old", "+new1", "+new2"])
    }

    @Test("Object with malformed hunk entries skips them gracefully")
    func malformedHunkEntriesSkipped() {
        let value: ClaudeJSONValue = .object([
            "structuredPatch": .array([
                // Valid hunk
                .object([
                    "oldStart": .int(1),
                    "oldLines": .int(1),
                    "newStart": .int(1),
                    "newLines": .int(1),
                    "lines": .array([.string(" a")])
                ]),
                // Missing newStart — skipped
                .object([
                    "oldStart": .int(2),
                    "oldLines": .int(1),
                    "newLines": .int(1),
                    "lines": .array([.string(" b")])
                ]),
                // Lines as non-array — skipped
                .object([
                    "oldStart": .int(3),
                    "oldLines": .int(1),
                    "newStart": .int(3),
                    "newLines": .int(1),
                    "lines": .string("not an array")
                ])
            ])
        ])
        let payload = ClaudeToolUseResult.from(value)
        #expect(payload?.structuredPatch?.count == 1)
        #expect(payload?.structuredPatch?.first?.oldStart == 1)
    }
}
