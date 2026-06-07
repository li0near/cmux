import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase F commit 1: the parser emits diff-styled body sections
/// directly so inline rendering and the detail-tab materializer both
/// read structurally typed Section.text(_, .diffAdded/.diffRemoved)
/// blocks instead of synthesizing a unified diff at click time.
@Suite("ToolInputParser.diffSections")
struct ToolInputParserDiffSectionsTests {

    @Test("Edit emits one removed/added pair from old_string and new_string")
    func editEmitsPair() {
        let input: ClaudeJSONValue = .object([
            "file_path": .string("/tmp/foo.swift"),
            "old_string": .string("let x = 1"),
            "new_string": .string("let x = 2")
        ])
        let sections = ToolInputParser.diffSections(name: "Edit", input: input)
        #expect(sections == [
            .text(["let x = 1"], style: .diffRemoved),
            .text(["let x = 2"], style: .diffAdded)
        ])
    }

    @Test("MultiEdit emits one pair per edit in arrival order — fixes editStrings's first-only loss")
    func multiEditEmitsAllPairs() {
        let input: ClaudeJSONValue = .object([
            "file_path": .string("/tmp/foo.swift"),
            "edits": .array([
                .object([
                    "old_string": .string("a1"),
                    "new_string": .string("b1")
                ]),
                .object([
                    "old_string": .string("a2"),
                    "new_string": .string("b2")
                ]),
                .object([
                    "old_string": .string("a3"),
                    "new_string": .string("b3")
                ])
            ])
        ])
        let sections = ToolInputParser.diffSections(name: "MultiEdit", input: input)
        #expect(sections == [
            .text(["a1"], style: .diffRemoved),
            .text(["b1"], style: .diffAdded),
            .text(["a2"], style: .diffRemoved),
            .text(["b2"], style: .diffAdded),
            .text(["a3"], style: .diffRemoved),
            .text(["b3"], style: .diffAdded)
        ])
    }

    @Test("MultiEdit skips malformed edit entries but keeps well-formed ones")
    func multiEditSkipsMalformed() {
        let input: ClaudeJSONValue = .object([
            "edits": .array([
                .object([
                    "old_string": .string("a1"),
                    "new_string": .string("b1")
                ]),
                .object([
                    "old_string": .string("a2")
                ]),
                .object([
                    "old_string": .string("a3"),
                    "new_string": .string("b3")
                ])
            ])
        ])
        let sections = ToolInputParser.diffSections(name: "MultiEdit", input: input)
        #expect(sections == [
            .text(["a1"], style: .diffRemoved),
            .text(["b1"], style: .diffAdded),
            .text(["a3"], style: .diffRemoved),
            .text(["b3"], style: .diffAdded)
        ])
    }

    @Test("MultiEdit with empty edits array returns nil")
    func multiEditEmptyArrayReturnsNil() {
        let input: ClaudeJSONValue = .object(["edits": .array([])])
        #expect(ToolInputParser.diffSections(name: "MultiEdit", input: input) == nil)
    }

    @Test("Edit without both old_string and new_string returns nil")
    func editMissingFieldsReturnsNil() {
        let input: ClaudeJSONValue = .object([
            "file_path": .string("/tmp/foo.swift"),
            "old_string": .string("let x = 1")
        ])
        #expect(ToolInputParser.diffSections(name: "Edit", input: input) == nil)
    }

    @Test("Non-Edit tool name returns nil")
    func otherToolReturnsNil() {
        let input: ClaudeJSONValue = .object([
            "old_string": .string("a"),
            "new_string": .string("b")
        ])
        #expect(ToolInputParser.diffSections(name: "Read", input: input) == nil)
        #expect(ToolInputParser.diffSections(name: "Write", input: input) == nil)
        #expect(ToolInputParser.diffSections(name: "Bash", input: input) == nil)
    }

    @Test("Nil input returns nil")
    func nilInputReturnsNil() {
        #expect(ToolInputParser.diffSections(name: "Edit", input: nil) == nil)
    }

    @Test("Multi-line strings preserved as a single block per side")
    func multiLineStringsPreservedAsSingleBlock() {
        let oldStr = "func foo() {\n    return 1\n}"
        let newStr = "func foo() {\n    return 2\n}"
        let input: ClaudeJSONValue = .object([
            "old_string": .string(oldStr),
            "new_string": .string(newStr)
        ])
        let sections = ToolInputParser.diffSections(name: "Edit", input: input)
        #expect(sections == [
            .text([oldStr], style: .diffRemoved),
            .text([newStr], style: .diffAdded)
        ])
    }
}
