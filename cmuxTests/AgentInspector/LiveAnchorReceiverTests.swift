import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the `claude_anchor` payload → user-chunk FIFO drain
/// algorithm. Exercises the pure free function
/// `pairClaudeAnchorsToUserChunks(...)`; the panel's plumbing simply
/// applies each `ClaudeAnchorPairing` through `TurnAnchorStore`.
final class LiveAnchorReceiverTests: XCTestCase {

    private func userChunk(_ id: String) -> AgentChunk {
        .user(UserChunk(id: id, text: "p \(id)", startTime: Date()))
    }

    private func aiChunk(_ id: String) -> AgentChunk {
        .ai(AIChunk(
            id: id,
            assistantText: "",
            thinkingText: "",
            toolCalls: [],
            model: nil,
            startTime: Date()
        ))
    }

    private func payload(turnId: String, row: UInt64, total: UInt64 = 1000) -> ClaudeAnchorPayload {
        ClaudeAnchorPayload(
            sessionId: "session-1",
            surfaceId: UUID(),
            turnId: turnId,
            transcriptPath: "",
            transcriptBytes: 0,
            terminalRowAtSubmit: row,
            totalAtCapture: total,
            capturedAt: Date()
        )
    }

    // MARK: - Empty / no work

    func testEmptyQueueReturnsNoPairings() {
        let result = pairClaudeAnchorsToUserChunks(
            chunks: [userChunk("u1")],
            queue: [],
            isAnchored: { _ in false }
        )
        XCTAssertTrue(result.pairings.isEmpty)
        XCTAssertTrue(result.remainingQueue.isEmpty)
    }

    func testEmptyChunksLeavesQueueIntact() {
        let p1 = payload(turnId: "t1", row: 10)
        let result = pairClaudeAnchorsToUserChunks(
            chunks: [],
            queue: [p1],
            isAnchored: { _ in false }
        )
        XCTAssertTrue(result.pairings.isEmpty)
        XCTAssertEqual(result.remainingQueue, [p1])
    }

    // MARK: - FIFO matching

    func testSinglePayloadPairsWithFirstUnanchoredUserChunk() {
        let chunks = [userChunk("u1"), aiChunk("a1")]
        let p1 = payload(turnId: "t1", row: 100)
        let result = pairClaudeAnchorsToUserChunks(
            chunks: chunks,
            queue: [p1],
            isAnchored: { _ in false }
        )
        XCTAssertEqual(result.pairings, [
            ClaudeAnchorPairing(userChunkId: "u1", payload: p1)
        ])
        XCTAssertTrue(result.remainingQueue.isEmpty)
    }

    func testMultiplePayloadsPairFifoWithMultipleUserChunks() {
        let chunks = [
            userChunk("u1"), aiChunk("a1"),
            userChunk("u2"), aiChunk("a2"),
            userChunk("u3")
        ]
        let p1 = payload(turnId: "t1", row: 100)
        let p2 = payload(turnId: "t2", row: 250)
        let p3 = payload(turnId: "t3", row: 400)
        let result = pairClaudeAnchorsToUserChunks(
            chunks: chunks,
            queue: [p1, p2, p3],
            isAnchored: { _ in false }
        )
        XCTAssertEqual(result.pairings, [
            ClaudeAnchorPairing(userChunkId: "u1", payload: p1),
            ClaudeAnchorPairing(userChunkId: "u2", payload: p2),
            ClaudeAnchorPairing(userChunkId: "u3", payload: p3)
        ])
        XCTAssertTrue(result.remainingQueue.isEmpty)
    }

    func testAlreadyAnchoredUserChunksAreSkipped() {
        let chunks = [
            userChunk("u1"), aiChunk("a1"),
            userChunk("u2"), aiChunk("a2"),
            userChunk("u3")
        ]
        // u1 and u2 already have anchors; only u3 is unanchored.
        let p1 = payload(turnId: "t-new", row: 500)
        let result = pairClaudeAnchorsToUserChunks(
            chunks: chunks,
            queue: [p1],
            isAnchored: { ["u1", "u2"].contains($0) }
        )
        XCTAssertEqual(result.pairings, [
            ClaudeAnchorPairing(userChunkId: "u3", payload: p1)
        ])
        XCTAssertTrue(result.remainingQueue.isEmpty)
    }

    func testQueueLongerThanAvailableUserChunksLeavesResidual() {
        let chunks = [userChunk("u1")]
        let p1 = payload(turnId: "t1", row: 100)
        let p2 = payload(turnId: "t2", row: 200)
        let result = pairClaudeAnchorsToUserChunks(
            chunks: chunks,
            queue: [p1, p2],
            isAnchored: { _ in false }
        )
        XCTAssertEqual(result.pairings, [
            ClaudeAnchorPairing(userChunkId: "u1", payload: p1)
        ])
        XCTAssertEqual(result.remainingQueue, [p2])
    }

    func testUserChunksWithoutQueueRemainUnanchored() {
        // Pre-inspector / resumed-painted user chunks: no payload was
        // queued for them. They get no anchor — the visible-turn filter
        // routes them through the .preAnchored regime instead.
        let chunks = [
            userChunk("u-old1"), aiChunk("a-old1"),
            userChunk("u-old2"), aiChunk("a-old2"),
            userChunk("u-new1")
        ]
        let p1 = payload(turnId: "t-new1", row: 600)
        let result = pairClaudeAnchorsToUserChunks(
            chunks: chunks,
            queue: [p1],
            // u-old1 and u-old2 are NOT anchored — they're pre-inspector
            // and live without anchors. The drain should still pair the
            // queue head with the FIRST unanchored user chunk in order,
            // which is u-old1 (FIFO semantics — payloads land in the
            // order they were submitted, matching user-chunk order in
            // the JSONL). When this happens in real life, the drain
            // races with stream observation: payloads queued at submit
            // time are guaranteed to arrive in the same order as the
            // user chunks they belong to.
            isAnchored: { _ in false }
        )
        XCTAssertEqual(result.pairings.first?.userChunkId, "u-old1")
        XCTAssertTrue(result.remainingQueue.isEmpty)
    }

    // MARK: - Notification payload key roundtrip

    func testNotificationPayloadKeyDecodes() {
        let surface = UUID()
        let p = ClaudeAnchorPayload(
            sessionId: "s1",
            surfaceId: surface,
            turnId: "t1",
            transcriptPath: "/tmp/x.jsonl",
            transcriptBytes: 4096,
            terminalRowAtSubmit: 250,
            totalAtCapture: 500,
            capturedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let note = Notification(
            name: .cmuxClaudePromptSubmitted,
            object: nil,
            userInfo: [Notification.claudeAnchorPayloadKey: p]
        )
        XCTAssertEqual(note.claudeAnchorPayload, p)
    }
}
