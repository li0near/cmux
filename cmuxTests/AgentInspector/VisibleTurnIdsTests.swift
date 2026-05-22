import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-data unit tests for `computeVisibleTurnIds`. Drives the algorithm
/// with synthesised `(scrollbar, chunks, anchors)` triples — no Ghostty
/// surface, no observer.
final class VisibleTurnIdsTests: XCTestCase {

    // MARK: - Fixtures

    private func userChunk(_ id: String, at offset: TimeInterval = 0) -> AgentChunk {
        .user(UserChunk(
            id: id,
            text: "prompt \(id)",
            startTime: Date(timeIntervalSinceReferenceDate: offset)
        ))
    }

    private func aiChunk(_ id: String, at offset: TimeInterval = 0) -> AgentChunk {
        .ai(AIChunk(
            id: id,
            assistantText: "response",
            thinkingText: "",
            toolCalls: [],
            model: "claude-sonnet-4-5",
            startTime: Date(timeIntervalSinceReferenceDate: offset)
        ))
    }

    private func systemChunk(_ id: String, at offset: TimeInterval = 0) -> AgentChunk {
        .system(SystemChunk(
            id: id,
            output: "system output",
            startTime: Date(timeIntervalSinceReferenceDate: offset)
        ))
    }

    private func compactChunk(_ id: String, at offset: TimeInterval = 0) -> AgentChunk {
        .compact(CompactChunk(
            id: id,
            summary: "[compacted]",
            startTime: Date(timeIntervalSinceReferenceDate: offset)
        ))
    }

    private func anchor(_ userId: String, row: UInt64, ai: String? = nil) -> TurnAnchor {
        TurnAnchor(
            userChunkId: userId,
            aiChunkId: ai,
            terminalRowAtSubmit: row,
            capturedAt: Date()
        )
    }

    // MARK: - Empty stream

    func testEmptyStreamReturnsEmptySet() {
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 100, offset: 0, len: 50),
            chunks: [],
            anchors: []
        )
        XCTAssertEqual(result, [])
    }

    func testNilScrollbarReturnsEmptySet() {
        let result = computeVisibleTurnIds(
            scrollbar: nil,
            chunks: [userChunk("u1")],
            anchors: []
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - At-bottom snap

    func testAtBottomReturnsLatestUserChunk() {
        let chunks = [
            userChunk("u1"),
            aiChunk("a1"),
            userChunk("u2"),
            aiChunk("a2")
        ]
        // viewportEnd == total ⇒ at bottom
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 950, len: 50),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["u2"])
    }

    func testAtBottomWithNoUsersReturnsLatestChunk() {
        let chunks = [systemChunk("s1"), systemChunk("s2"), systemChunk("s3")]
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 100, offset: 90, len: 10),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["s3"])
    }

    func testAtBottomWhenScrollbackFitsViewport() {
        // total <= len ⇒ always at bottom
        let chunks = [userChunk("u1"), aiChunk("a1")]
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 50, offset: 0, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["u1"])
    }

    // MARK: - Anchored

    func testSingleFullyVisibleUserPromptAnchorsThere() {
        let chunks = [
            userChunk("u1"),
            aiChunk("a1"),
            userChunk("u2"),
            aiChunk("a2"),
            userChunk("u3"),
            aiChunk("a3")
        ]
        let anchors = [
            anchor("u1", row: 100),
            anchor("u2", row: 250),
            anchor("u3", row: 400)
        ]
        // Viewport: rows 200..299. Only u2 (row 250) is fully visible.
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 200, len: 100),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, ["u2"])
    }

    func testMultipleFullyVisiblePromptsAreUnioned() {
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3"),
            userChunk("u4")
        ]
        let anchors = [
            anchor("u1", row: 100),
            anchor("u2", row: 250),
            anchor("u3", row: 350),
            anchor("u4", row: 500)
        ]
        // Viewport: rows 200..400. u2 (250) and u3 (350) are fully visible.
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 200, len: 200),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, ["u2", "u3"])
    }

    func testNoFullyVisiblePromptUsesPromptBeforeViewport() {
        let chunks = [
            userChunk("u1"),
            aiChunk("a1"),
            userChunk("u2"),
            aiChunk("a2")
        ]
        let anchors = [
            anchor("u1", row: 100, ai: "a1"),
            anchor("u2", row: 600, ai: "a2")
        ]
        // Viewport: rows 300..400. We're mid-AI-response of u1's turn —
        // no user prompt is fully visible. Should anchor on u1 (the
        // prompt that initiated the visible response).
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 300, len: 100),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, ["u1"])
    }

    // MARK: - Proportional fallback

    func testProportionalFallbackFloorsToPromptAtOrBeforeRegion() {
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3"),
            userChunk("u4"),
            userChunk("u5")
        ]
        // No anchors. Viewport at the middle of the scrollback —
        // fraction = 100 / (1000 - 100) ≈ 0.111.
        // lastIndex = 4. Int(4 * 0.111) = 0 (floor). Should pick u1.
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 100, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["u1"])
    }

    func testProportionalFallbackFloorsAtThreeQuarters() {
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3"),
            userChunk("u4"),
            userChunk("u5")
        ]
        // fraction = 675 / (1000 - 100) = 0.75 ⇒ Int(4 * 0.75) = 3 ⇒ u4
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 675, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["u4"])
    }

    func testProportionalFallbackWhenViewportAboveAllAnchors() {
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3")
        ]
        // Anchor exists for u3, but viewport is above its row — no
        // anchor matches the visible region. Falls through to
        // proportional. fraction = 50 / (1000 - 100) ≈ 0.0555 ⇒
        // Int(2 * 0.0555) = 0 ⇒ u1.
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 50, len: 100),
            chunks: chunks,
            anchors: [anchor("u3", row: 800)]
        )
        XCTAssertEqual(result, ["u1"])
    }

    func testProportionalFallbackWithNoUserChunks() {
        // Stream with only system chunks — pool falls back to all chunk ids.
        let chunks = [
            systemChunk("s1"),
            systemChunk("s2"),
            systemChunk("s3"),
            systemChunk("s4")
        ]
        // fraction = 100 / (1000 - 100) ≈ 0.111 ⇒ Int(3 * 0.111) = 0 ⇒ s1
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 100, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["s1"])
    }

    // MARK: - Compaction is informational only

    func testCompactionDoesNotGateProportionalFallback() {
        // Stream contains a compact chunk early. v1 used to restrict the
        // proportional pool to post-compaction chunks; v2 must always
        // show some turn (compaction is a visible boundary chip but
        // doesn't gate sync).
        let chunks = [
            userChunk("u1"),
            compactChunk("c1"),
            userChunk("u2"),
            userChunk("u3")
        ]
        // Viewport near the top — fraction floors to user index 0.
        let result = computeVisibleTurnIds(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 0, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, ["u1"])
    }
}
