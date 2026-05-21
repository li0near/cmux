import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the Codex chunk-builder against a recorded fixture.
final class CodexChunkBuilderTests: XCTestCase {

    private func fixtureURL() -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: "codex-sample", withExtension: "jsonl") {
            return url
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentInspector/codex-sample.jsonl")
    }

    private func decodeFixture() throws -> [CodexRolloutLine] {
        let raw = try String(contentsOf: fixtureURL(), encoding: .utf8)
        return try raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try AgentInspectorJSON.decoder.decode(CodexRolloutLine.self, from: Data(line.utf8))
            }
    }

    func testFixtureDecodes() throws {
        let lines = try decodeFixture()
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines[0].sessionMeta?.id, "codex-1")
        XCTAssertEqual(lines[1].turnContext?.model, "o4")
        XCTAssertEqual(lines[2].eventMsg?.innerType, "thread_name_updated")
        XCTAssertEqual(lines[3].eventMsg?.innerType, "user_message")
        XCTAssertEqual(lines[4].responseItem?.role, "assistant")
        XCTAssertEqual(lines[4].responseItem?.textBlocks.first, "I'll start by reading the current code.")
    }

    func testChunkBuilderProducesExpectedChunks() throws {
        let lines = try decodeFixture()
        var builder = CodexChunkBuilder()
        var stamp = 0
        builder.stampForIndex = { idx in
            Date(timeIntervalSince1970: TimeInterval(idx) * 60)
        }
        for line in lines {
            builder.ingest(line)
            stamp += 1
        }
        let chunks = builder.snapshot()

        // Expected (filtered):
        //   user_message → UserChunk
        //   two consecutive assistant items → one AIChunk
        //   noise system-reminder user → filtered
        //   real user "proceed" → UserChunk (flushes the AI chunk)
        //   final assistant → AIChunk (still pending until snapshot)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(builder.sessionMeta?.id, "codex-1")

        if case .user(let u) = chunks[0] {
            XCTAssertEqual(u.text, "Plan a refactor of the widget renderer.")
        } else {
            XCTFail("chunks[0] should be UserChunk")
        }
        if case .ai(let ai) = chunks[1] {
            XCTAssertTrue(ai.assistantText.contains("reading the current code"))
            XCTAssertTrue(ai.assistantText.contains("WidgetView"))
            XCTAssertEqual(ai.model, "o4")
        } else {
            XCTFail("chunks[1] should be AIChunk")
        }
        if case .user(let u) = chunks[2] {
            XCTAssertEqual(u.text, "Sounds good, proceed.")
        } else {
            XCTFail("chunks[2] should be UserChunk")
        }
        if case .ai(let ai) = chunks[3] {
            XCTAssertTrue(ai.assistantText.contains("Done. Here's the diff."))
        } else {
            XCTFail("chunks[3] should be AIChunk")
        }
    }

    func testSyntheticTimestampsMonotonic() {
        let stamps = CodexSyntheticTimestamps(
            baseStart: Date(timeIntervalSince1970: 0),
            baseEnd: Date(timeIntervalSince1970: 100),
            totalLines: 10
        )
        for i in 0..<9 {
            XCTAssertLessThan(stamps.stamp(for: i), stamps.stamp(for: i + 1))
        }
    }
}
