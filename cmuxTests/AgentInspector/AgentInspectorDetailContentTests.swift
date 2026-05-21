import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the detail-content resolver that translates an
/// `InspectorDetailRequest` into the static frozen content shown by an
/// `AgentInspectorPanel.detail(_)` tab.
final class AgentInspectorDetailContentTests: XCTestCase {

    private let chunkStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func userChunk(id: String = "u1", text: String = "Hello there") -> AgentChunk {
        .user(UserChunk(id: id, text: text, startTime: chunkStart))
    }

    private func aiChunk(
        id: String = "a1",
        thinking: String = "",
        tools: [AgentToolCall] = []
    ) -> AgentChunk {
        .ai(AIChunk(
            id: id,
            assistantText: "irrelevant",
            thinkingText: thinking,
            toolCalls: tools,
            model: "claude-sonnet-4-5",
            startTime: chunkStart
        ))
    }

    private func systemChunk(id: String = "s1", output: String = "build succeeded") -> AgentChunk {
        .system(SystemChunk(id: id, output: output, startTime: chunkStart))
    }

    // MARK: User prompt

    func testUserPromptResolves() {
        let chunk = userChunk(text: "Read foo.ts please")
        let content = AgentInspectorDetailContent.resolve(
            request: .userPrompt(chunkId: "u1"),
            chunk: chunk
        )
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "User prompt")
        XCTAssertEqual(content?.body, "Read foo.ts please")
        XCTAssertEqual(content?.kind, .userPrompt)
        XCTAssertEqual(content?.sourceChunkId, "u1")
    }

    func testUserPromptIdMismatchReturnsNil() {
        let chunk = userChunk(id: "u1")
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .userPrompt(chunkId: "u-different"),
            chunk: chunk
        ))
    }

    func testEmptyUserPromptReturnsNil() {
        let chunk = userChunk(text: "   \n  ")
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .userPrompt(chunkId: "u1"),
            chunk: chunk
        ))
    }

    // MARK: Thinking

    func testThinkingResolves() {
        let chunk = aiChunk(thinking: "I should consider X.\nThen Y.")
        let content = AgentInspectorDetailContent.resolve(
            request: .thinking(chunkId: "a1"),
            chunk: chunk
        )
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Thinking")
        XCTAssertEqual(content?.body, "I should consider X.\nThen Y.")
        XCTAssertEqual(content?.kind, .thinking)
    }

    func testEmptyThinkingReturnsNil() {
        let chunk = aiChunk(thinking: "")
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .thinking(chunkId: "a1"),
            chunk: chunk
        ))
    }

    // MARK: System output

    func testSystemOutputResolves() {
        let chunk = systemChunk(output: "Set model to sonnet")
        let content = AgentInspectorDetailContent.resolve(
            request: .systemOutput(chunkId: "s1"),
            chunk: chunk
        )
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "System output")
        XCTAssertEqual(content?.body, "Set model to sonnet")
        XCTAssertEqual(content?.kind, .systemOutput)
    }

    // MARK: Tool input / result

    func testToolInputResolves() {
        let tool = AgentToolCall(
            id: "t1",
            name: "Read",
            summary: "/foo.ts",
            inputDetail: "file_path: /foo.ts",
            result: "x = 1",
            isError: false
        )
        let chunk = aiChunk(tools: [tool])
        let content = AgentInspectorDetailContent.resolve(
            request: .toolInput(chunkId: "a1", toolId: "t1"),
            chunk: chunk
        )
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Tool input · Read")
        XCTAssertEqual(content?.body, "file_path: /foo.ts")
        if case .toolInput(let toolName) = content?.kind {
            XCTAssertEqual(toolName, "Read")
        } else {
            XCTFail("expected .toolInput kind")
        }
    }

    func testToolResultResolvesAndPreservesErrorFlag() {
        let tool = AgentToolCall(
            id: "t1",
            name: "Bash",
            summary: "rg foo",
            inputDetail: "command: rg foo",
            result: "Exit code 1\nrg: not found",
            isError: true
        )
        let chunk = aiChunk(tools: [tool])
        let content = AgentInspectorDetailContent.resolve(
            request: .toolResult(chunkId: "a1", toolId: "t1"),
            chunk: chunk
        )
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Tool result · Bash")
        if case .toolResult(let toolName, let isError) = content?.kind {
            XCTAssertEqual(toolName, "Bash")
            XCTAssertTrue(isError)
        } else {
            XCTFail("expected .toolResult kind")
        }
    }

    func testToolResultMissingReturnsNil() {
        let tool = AgentToolCall(
            id: "t1",
            name: "Read",
            summary: "/foo.ts",
            inputDetail: "file_path: /foo.ts",
            result: nil, // pending
            isError: false
        )
        let chunk = aiChunk(tools: [tool])
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .toolResult(chunkId: "a1", toolId: "t1"),
            chunk: chunk
        ))
    }

    func testToolMissingReturnsNil() {
        let chunk = aiChunk(tools: [])
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .toolInput(chunkId: "a1", toolId: "t-missing"),
            chunk: chunk
        ))
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .toolResult(chunkId: "a1", toolId: "t-missing"),
            chunk: chunk
        ))
    }

    func testWrongChunkVariantReturnsNil() {
        // Asking for thinking on a user chunk should yield nil.
        let chunk = userChunk(id: "u1")
        XCTAssertNil(AgentInspectorDetailContent.resolve(
            request: .thinking(chunkId: "u1"),
            chunk: chunk
        ))
    }
}
