import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-data unit tests for `computeVisibleTurnFilter`. Drives the
/// algorithm with synthesised `(scrollbar, chunks, anchors)` triples —
/// no Ghostty surface, no observer.
final class VisibleTurnFilterTests: XCTestCase {

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

    private func anchor(_ userId: String, row: UInt64, totalAtCapture: UInt64 = 0, ai: String? = nil) -> TurnAnchor {
        TurnAnchor(
            userChunkId: userId,
            aiChunkId: ai,
            terminalRowAtSubmit: row,
            totalAtCapture: totalAtCapture,
            capturedAt: Date()
        )
    }

    // MARK: - Empty / nil

    func testEmptyStreamReturnsEmptyTurnsSet() {
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 100, offset: 0, len: 50),
            chunks: [],
            anchors: []
        )
        XCTAssertEqual(result, .turns([]))
    }

    func testNilScrollbarWithEmptyChunksReturnsEmptyTurnsSet() {
        // Both scrollbar nil AND chunks empty: nothing to show.
        let result = computeVisibleTurnFilter(
            scrollbar: nil,
            chunks: [],
            anchors: []
        )
        XCTAssertEqual(result, .turns([]))
    }

    // MARK: - At-bottom

    func testAtBottomReturnsLatestUserChunk() {
        let chunks = [
            userChunk("u1"),
            aiChunk("a1"),
            userChunk("u2"),
            aiChunk("a2")
        ]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 950, len: 50),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .turns(["u2"]))
    }

    func testAtBottomWithNoUsersReturnsLatestChunk() {
        let chunks = [systemChunk("s1"), systemChunk("s2"), systemChunk("s3")]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 100, offset: 90, len: 10),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .turns(["s3"]))
    }

    func testAtBottomWhenScrollbackFitsViewport() {
        // total <= len ⇒ always at bottom
        let chunks = [userChunk("u1"), aiChunk("a1")]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 50, offset: 0, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .turns(["u1"]))
    }

    // MARK: - Anchored

    func testSingleFullyVisibleUserPromptAnchorsThere() {
        let chunks = [
            userChunk("u1"),
            aiChunk("a1"),
            userChunk("u2"),
            aiChunk("a2"),
            userChunk("u3")
        ]
        let anchors = [
            anchor("u1", row: 100),
            anchor("u2", row: 250),
            anchor("u3", row: 400)
        ]
        // Viewport: rows 200..299. Only u2 (row 250) is fully visible.
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 200, len: 100),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, .turns(["u2"]))
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
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 200, len: 200),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, .turns(["u2", "u3"]))
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
        // Viewport: rows 300..400. Mid-AI-response of u1's turn.
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 300, len: 100),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, .turns(["u1"]))
    }

    // MARK: - Pre-anchored

    func testViewportAboveAllAnchorsReturnsPreAnchored() {
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3")
        ]
        // Anchor only for u3, but viewport is below u3's row. With at
        // least one anchor present, viewport above all of them falls
        // through to the .preAnchored regime.
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 50, len: 100),
            chunks: chunks,
            anchors: [anchor("u3", row: 800)]
        )
        XCTAssertEqual(result, .preAnchored)
    }

    func testNoAnchorsAtAllAndNotAtBottomReturnsPreAnchored() {
        // Resumed-session shape: zero anchors, viewport not at-bottom
        // (well past the at-bottom tolerance band). The user scrolled
        // significantly off-bottom into the resumed-history zone.
        // Inspector enters .preAnchored — free-scroll the unanchored
        // history. The at-bottom tolerance prevents borderline flap
        // back to .turns([latest]) when the user is only a few rows
        // shy of `total`.
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3"),
            userChunk("u4")
        ]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 100, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .preAnchored)
    }

    func testAtBottomToleranceKeepsLatestTurnNearBottom() {
        // Viewport ends 2 rows shy of `total` — within the
        // atBottomToleranceRows band — should still register as
        // at-bottom and return the latest user chunk's turn.
        // Without the tolerance, mouse-wheel ticks and overscroll
        // bounce flap the filter into .preAnchored and back.
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3")
        ]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 948, len: 50),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .turns(["u3"]))
    }

    // MARK: - Latest-turn stay band (wider than at-bottom tolerance)

    func testUnanchoredStaysOnLatestWithinTwoViewportHeightsOfBottom() {
        // No anchors. total=1000, len=100. bandRows = 2*len = 200,
        // latestPromptRow ≈ total - bandRows = 800.
        // Viewport offset=820, end=920 — 80 rows shy of `total`, well
        // outside the historic at-bottom tolerance (3 rows). Under the
        // old at-bottom-only check this would flip to .preAnchored;
        // the wider stay band keeps it on .turns([u3]) so a small
        // scroll-up doesn't trigger the LazyVStack content-set swap.
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3")
        ]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 820, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .turns(["u3"]))
    }

    func testUnanchoredExpandsToPreAnchoredAboveStayBand() {
        // Same shape as above but viewport scrolled well above the
        // stay band: offset=500 → top is at row 500, bandRows=200,
        // latestPromptRow=800 — 500+3 < 800 → expand.
        // No anchors → fall through to .preAnchored.
        let chunks = [
            userChunk("u1"),
            userChunk("u2"),
            userChunk("u3")
        ]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 500, len: 100),
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .preAnchored)
    }

    func testAnchoredLatestStaysViaStayBandPath() {
        // Latest user chunk (u2) has an anchor at row 600.
        // latestPromptRow = 600 (exact, anchor totalAtCapture=0).
        // Viewport offset=650, end=750 — u2's anchor row 600 is NOT
        // inside [650, 750], so the "anchored fully-visible" path
        // does not match. The stay-band check (650+3 ≥ 600) returns
        // .turns([u2]) before falling through to "anchored before".
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
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 650, len: 100),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, .turns(["u2"]))
    }

    // MARK: - No-scrollbar cold attach

    func testNilScrollbarWithChunksReturnsLatestTurn() {
        // Cold attach / tab-switch / resume before Ghostty's first
        // scrollbar tick: scrollbar is nil but the stream already
        // has chunks. Must show the live tail, not an empty pane.
        let chunks = [
            userChunk("u1"),
            aiChunk("a1"),
            userChunk("u2"),
            aiChunk("a2")
        ]
        let result = computeVisibleTurnFilter(
            scrollbar: nil,
            chunks: chunks,
            anchors: []
        )
        XCTAssertEqual(result, .turns(["u2"]))
    }

    // MARK: - Resize scaling

    func testResizeScalingDoublesEffectiveRow() {
        // Anchor was captured when total=500, row=250 (the prompt sat at
        // the midpoint). Terminal resized; new total=1000. The scaled
        // effective row is 250 × 1000 / 500 = 500.
        // Viewport [400..600] should fully contain the scaled row.
        let chunks = [userChunk("u1"), aiChunk("a1")]
        let anchors = [anchor("u1", row: 250, totalAtCapture: 500, ai: "a1")]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 400, len: 200),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, .turns(["u1"]))
    }

    func testResizeScalingDisabledWhenTotalAtCaptureIsZero() {
        // totalAtCapture=0 means "synthetic / unscaled". Row is taken
        // verbatim regardless of current total.
        let chunks = [userChunk("u1")]
        let anchors = [anchor("u1", row: 250, totalAtCapture: 0)]
        let result = computeVisibleTurnFilter(
            scrollbar: VisibleTurnScrollSnapshot(total: 1000, offset: 200, len: 100),
            chunks: chunks,
            anchors: anchors
        )
        XCTAssertEqual(result, .turns(["u1"]))
    }

    // MARK: - inspectorScrollTarget

    private static let testChunkListId = "__test_list__"

    func testScrollTargetForTurnsReturnsContainerId() {
        let chunks = [userChunk("u1"), aiChunk("a1"), userChunk("u2"), aiChunk("a2")]
        let target = inspectorScrollTarget(
            chunks: chunks,
            filter: .turns(["u2"]),
            anchoredUserIds: [],
            chunkListId: Self.testChunkListId
        )
        XCTAssertEqual(target, Self.testChunkListId)
    }

    func testScrollTargetForAllReturnsContainerId() {
        let chunks = [userChunk("u1"), aiChunk("a1")]
        let target = inspectorScrollTarget(
            chunks: chunks,
            filter: .all,
            anchoredUserIds: [],
            chunkListId: Self.testChunkListId
        )
        XCTAssertEqual(target, Self.testChunkListId)
    }

    func testScrollTargetForPreAnchoredUnanchoredLatestReturnsLastBeforeLatestUser() {
        // Resumed session: nobody is anchored. .preAnchored renders all
        // chunks. Target should be the chunk just before the latest user
        // prompt so the viewport bottom lands on pre-last-turn content.
        let chunks = [
            userChunk("u1"), aiChunk("a1"),
            userChunk("u2"), aiChunk("a2"),
            userChunk("u3"), aiChunk("a3")
        ]
        let target = inspectorScrollTarget(
            chunks: chunks,
            filter: .preAnchored,
            anchoredUserIds: [],
            chunkListId: Self.testChunkListId
        )
        XCTAssertEqual(target, "a2")
    }

    func testScrollTargetForPreAnchoredAnchoredLatestReturnsContainerId() {
        // Latest user (u2) is anchored. .preAnchored excludes u2's
        // chunks from the rendered set; the rendered set's natural
        // bottom IS the pre-last-turn boundary, so the container id
        // suffices.
        let chunks = [
            userChunk("u1"), aiChunk("a1"),
            userChunk("u2"), aiChunk("a2")
        ]
        let target = inspectorScrollTarget(
            chunks: chunks,
            filter: .preAnchored,
            anchoredUserIds: ["u2"],
            chunkListId: Self.testChunkListId
        )
        XCTAssertEqual(target, Self.testChunkListId)
    }

    func testScrollTargetForPreAnchoredSingleUserReturnsContainerId() {
        // Only one user prompt and nothing before it — there is no
        // "chunk before the latest user" to land on. Fall back to
        // the container id (LazyVStack bottom).
        let chunks = [userChunk("u1"), aiChunk("a1")]
        let target = inspectorScrollTarget(
            chunks: chunks,
            filter: .preAnchored,
            anchoredUserIds: [],
            chunkListId: Self.testChunkListId
        )
        XCTAssertEqual(target, Self.testChunkListId)
    }

    func testScrollTargetForPreAnchoredEmptyChunksReturnsContainerId() {
        let target = inspectorScrollTarget(
            chunks: [],
            filter: .preAnchored,
            anchoredUserIds: [],
            chunkListId: Self.testChunkListId
        )
        XCTAssertEqual(target, Self.testChunkListId)
    }
}
