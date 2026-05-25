import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the chunk classification + AI-chunk merging logic against a
/// recorded fixture session.
final class ClaudeChunkBuilderTests: XCTestCase {

    private func fixtureURL() -> URL {
        let bundle = Bundle(for: type(of: self))
        // Xcode flattens resources into Resources/ regardless of directory
        // structure in the source tree, so we look up by basename.
        if let url = bundle.url(forResource: "claude-sample", withExtension: "jsonl") {
            return url
        }
        // Fallback for direct invocations (e.g. swift-package-style tests):
        // walk from this source file up to the cmux repo root, then dive
        // into cmuxTests/Resources/AgentInspector.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentInspector/claude-sample.jsonl")
    }

    private func decodeFixture() throws -> [ClaudeJSONLLine] {
        let url = fixtureURL()
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let data = Data(line.utf8)
                return try AgentInspectorJSON.decoder.decode(ClaudeJSONLLine.self, from: data)
            }
    }

    func testFixtureDecodesAllLines() throws {
        let lines = try decodeFixture()
        XCTAssertEqual(lines.count, 9, "Expected 9 lines in claude-sample.jsonl")
    }

    func testChunkBuilderProducesExpectedChunks() throws {
        let lines = try decodeFixture()
        var builder = ClaudeChunkBuilder()
        for line in lines { builder.ingest(line) }
        let chunks = builder.snapshot()

        // Expected ordering:
        //   summary line (hard noise) → skipped
        //   user (string) → UserChunk
        //   assistant w/ text+thinking+tool_use → AIChunk (in progress)
        //   user isMeta=true tool_result → folded into same AIChunk
        //   assistant final text → still same AIChunk; flushed by next non-AI
        //   user system stdout → SystemChunk (also flushes the AI chunk)
        //   user system-reminder → hard noise (skipped)
        //   system entry → hard noise (skipped)
        //   compact summary → CompactChunk
        XCTAssertEqual(chunks.count, 4, "Expected 4 visible chunks")

        guard chunks.count == 4 else { return }

        if case .user(let u) = chunks[0] {
            XCTAssertEqual(u.text, "Hello, please read foo.ts")
        } else {
            XCTFail("chunks[0] should be a UserChunk, got \(chunks[0])")
        }

        if case .ai(let ai) = chunks[1] {
            XCTAssertTrue(ai.assistantText.contains("Let me read foo.ts."))
            XCTAssertTrue(ai.assistantText.contains("foo.ts exports x and y."))
            XCTAssertEqual(ai.thinkingText, "I should read foo.ts")
            XCTAssertEqual(ai.toolCalls.count, 1)
            XCTAssertEqual(ai.toolCalls[0].name, "Read")
            XCTAssertEqual(ai.toolCalls[0].summary, "/Users/dev/proj/foo.ts")
            XCTAssertEqual(ai.toolCalls[0].inputDetail, "file_path: /Users/dev/proj/foo.ts")
            XCTAssertNotNil(ai.toolCalls[0].result)
            XCTAssertTrue(ai.toolCalls[0].result?.contains("export const x") ?? false)
            XCTAssertEqual(ai.model, "claude-sonnet-4-5")
            XCTAssertEqual(ai.usage.inputTokens, 25)
            XCTAssertEqual(ai.usage.outputTokens, 32)
            // endTime should be the last folded message's timestamp
            // (assistant a2 at 10:00:04). Duration = 2s.
            XCTAssertNotNil(ai.endTime)
            if let end = ai.endTime {
                XCTAssertEqual(end.timeIntervalSince(ai.startTime), 2.0, accuracy: 0.01)
            }
        } else {
            XCTFail("chunks[1] should be an AIChunk, got \(chunks[1])")
        }

        if case .system(let s) = chunks[2] {
            XCTAssertEqual(s.output, "Set model to sonnet")
        } else {
            XCTFail("chunks[2] should be a SystemChunk, got \(chunks[2])")
        }

        if case .compact(let c) = chunks[3] {
            XCTAssertTrue(c.summary.contains("widget rendering"))
        } else {
            XCTFail("chunks[3] should be a CompactChunk, got \(chunks[3])")
        }
    }

    // MARK: - Classification edge cases

    func testHardNoiseFiltering() {
        let cases: [(String, ClaudeChunkBuilder.Category)] = [
            ("system", .hardNoise),
            ("summary", .hardNoise),
            ("file-history-snapshot", .hardNoise),
            ("queue-operation", .hardNoise),
        ]
        let builder = ClaudeChunkBuilder()
        for (type, expected) in cases {
            let line = ClaudeJSONLLine(
                type: type, timestamp: nil, uuid: nil, parentUuid: nil,
                isSidechain: nil, isMeta: nil, message: nil,
                isCompactSummary: nil, summary: nil
            )
            XCTAssertEqual(builder.classify(line), expected, "type=\(type)")
        }
    }

    func testInterruptionMessageFlowsAsAI() {
        let line = ClaudeJSONLLine(
            type: "user", timestamp: nil, uuid: "uX", parentUuid: nil,
            isSidechain: nil, isMeta: nil,
            message: ClaudeMessage(
                role: "user", model: nil,
                content: .text("[Request interrupted by user for new request]"),
                stopReason: nil
            ),
            isCompactSummary: nil, summary: nil
        )
        let builder = ClaudeChunkBuilder()
        XCTAssertEqual(builder.classify(line), .ai)
    }

    func testToolSummarisation() {
        let bashInput = ClaudeJSONValue.object([
            "command": .string("rg --no-heading -n foo")
        ])
        XCTAssertEqual(
            ClaudeChunkBuilder.summarizeToolInput(name: "Bash", input: bashInput),
            "rg --no-heading -n foo"
        )

        let readInput = ClaudeJSONValue.object([
            "file_path": .string("/tmp/x.ts")
        ])
        XCTAssertEqual(
            ClaudeChunkBuilder.summarizeToolInput(name: "Read", input: readInput),
            "/tmp/x.ts"
        )

        let taskInput = ClaudeJSONValue.object([
            "description": .string("Search for foo"),
            "prompt": .string("Find every reference to foo"),
        ])
        XCTAssertEqual(
            ClaudeChunkBuilder.summarizeToolInput(name: "Task", input: taskInput),
            "Search for foo"
        )
    }

    func testFlattenToolResultArrayShape() {
        let arr = ClaudeJSONValue.array([
            .object(["type": .string("text"), "text": .string("hello")]),
            .object(["type": .string("text"), "text": .string("world")]),
        ])
        XCTAssertEqual(
            ClaudeChunkBuilder.flattenToolResult(arr),
            "hello\nworld"
        )
    }

    func testEmptyStdoutIsHardNoise() {
        let line = ClaudeJSONLLine(
            type: "user", timestamp: nil, uuid: nil, parentUuid: nil,
            isSidechain: nil, isMeta: nil,
            message: ClaudeMessage(
                role: "user", model: nil,
                content: .text("<local-command-stdout></local-command-stdout>"),
                stopReason: nil
            ),
            isCompactSummary: nil, summary: nil
        )
        let builder = ClaudeChunkBuilder()
        XCTAssertEqual(builder.classify(line), .hardNoise)
    }

    func testResetClearsState() {
        var builder = ClaudeChunkBuilder()
        let userLine = ClaudeJSONLLine(
            type: "user", timestamp: nil, uuid: "u1", parentUuid: nil,
            isSidechain: nil, isMeta: nil,
            message: ClaudeMessage(
                role: "user", model: nil,
                content: .text("hi"), stopReason: nil
            ),
            isCompactSummary: nil, summary: nil
        )
        builder.ingest(userLine)
        XCTAssertEqual(builder.snapshot().count, 1)
        builder.reset()
        XCTAssertEqual(builder.snapshot().count, 0)
    }

    // MARK: - Phase A integration: rewind tree

    private func decodeNamedFixture(_ name: String) throws -> [ClaudeJSONLLine] {
        let bundle = Bundle(for: type(of: self))
        let url: URL
        if let bundled = bundle.url(forResource: name, withExtension: "jsonl") {
            url = bundled
        } else {
            url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/AgentInspector/\(name).jsonl")
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try AgentInspectorJSON.decoder.decode(ClaudeJSONLLine.self, from: Data(line.utf8))
            }
    }

    func testRewindTreeFixtureFiltersAbandonedAndEmitsBranchLinks() throws {
        let lines = try decodeNamedFixture("claude-rewind-tree")
        var builder = ClaudeChunkBuilder()
        for line in lines { builder.ingest(line) }
        let chunks = builder.snapshot()

        // Active chain: u-root, u-active, a-active.
        // Two abandoned branches anchored at u-root → 2 BranchLink chunks.
        let users = chunks.compactMap { c -> String? in
            if case .user(let u) = c { return u.id } else { return nil }
        }
        XCTAssertEqual(users, ["u-root", "u-active"])

        let branchLinks = chunks.compactMap { c -> BranchLinkChunk? in
            if case .meta(.branchLink(let b)) = c { return b } else { return nil }
        }
        XCTAssertEqual(branchLinks.count, 2)
        XCTAssertEqual(branchLinks.first?.totalRewinds, 2)
    }

    // MARK: - Phase A integration: sidechain task

    func testSidechainTaskAttachesTranscriptToParentToolCall() throws {
        let lines = try decodeNamedFixture("claude-sidechain-task")
        var builder = ClaudeChunkBuilder()
        for line in lines { builder.ingest(line) }
        let chunks = builder.snapshot()

        // Find the AIChunk with the Task tool call.
        let aiChunks = chunks.compactMap { c -> AIChunk? in
            if case .ai(let ai) = c { return ai } else { return nil }
        }
        XCTAssertGreaterThan(aiChunks.count, 0)
        let taskCall = aiChunks
            .flatMap(\.toolCalls)
            .first(where: { $0.name == "Task" })
        XCTAssertNotNil(taskCall, "Task tool call should be present")
        XCTAssertNotNil(taskCall?.sidechainTranscript,
                        "Sidechain transcript should be attached")
        XCTAssertEqual(taskCall?.subagentType, "general-purpose")
    }

    // MARK: - Phase A integration: recap

    func testRecapFixtureEmitsRecapChunk() throws {
        let lines = try decodeNamedFixture("claude-recap")
        var builder = ClaudeChunkBuilder()
        for line in lines { builder.ingest(line) }
        let chunks = builder.snapshot()

        let recaps = chunks.compactMap { c -> RecapChunk? in
            if case .meta(.recap(let r)) = c { return r } else { return nil }
        }
        XCTAssertEqual(recaps.count, 1)
        XCTAssertTrue(recaps[0].body.contains("deploying the service"))
    }

    // MARK: - Phase A integration: multi-PR

    func testMultiPrFixtureEmitsTwoPrLinks() throws {
        let lines = try decodeNamedFixture("claude-multi-pr")
        var builder = ClaudeChunkBuilder()
        for line in lines { builder.ingest(line) }
        let chunks = builder.snapshot()

        let prs = chunks.compactMap { c -> PrLinkChunk? in
            if case .meta(.prLink(let p)) = c { return p } else { return nil }
        }
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[0].prNumber, 42)
        XCTAssertEqual(prs[1].prNumber, 7)
    }

    // MARK: - Phase A integration: meta content variety

    func testMetaContentFixtureClassifiesEachCategory() throws {
        let lines = try decodeNamedFixture("claude-meta-content")
        var builder = ClaudeChunkBuilder()
        for line in lines { builder.ingest(line) }
        let chunks = builder.snapshot()

        // Categories we expect to see (one each).
        var sawSlashCmdInput = 0
        var sawSlashCmdOutput = 0
        var sawLocalCommandCaveat = 0
        var sawSystemReminder = 0
        var sawContextUsage = 0
        var sawContinueResume = 0
        var sawSkillTitle = 0
        for chunk in chunks {
            guard case .meta(let m) = chunk else { continue }
            switch m {
            case .slashCmdInput:    sawSlashCmdInput += 1
            case .slashCmdOutput:   sawSlashCmdOutput += 1
            case .localCommandCaveat: sawLocalCommandCaveat += 1
            case .systemReminder:   sawSystemReminder += 1
            case .contextUsage:     sawContextUsage += 1
            case .continueResume:   sawContinueResume += 1
            case .skillTitle:       sawSkillTitle += 1
            case .branchLink, .recap, .prLink: break
            }
        }
        // Two slashCmdInput entries: built-in /model and skill /browse-url.
        XCTAssertEqual(sawSlashCmdInput, 2)
        XCTAssertEqual(sawSlashCmdOutput, 1)
        XCTAssertEqual(sawLocalCommandCaveat, 1)
        XCTAssertEqual(sawSystemReminder, 1)
        XCTAssertEqual(sawContextUsage, 1)
        XCTAssertEqual(sawContinueResume, 1)
        XCTAssertEqual(sawSkillTitle, 1)
    }
}
