import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TurnAnchorStoreTests: XCTestCase {

    func testRecordsTurnStart() {
        let store = TurnAnchorStore()
        store.setSurface(workspaceId: UUID(), surfaceId: UUID())
        store.recordTurnStart(userChunkId: "u1", terminalRow: 100)
        let anchor = store.anchor(forChunkId: "u1")
        XCTAssertEqual(anchor?.terminalRowAtSubmit, 100)
        XCTAssertNil(anchor?.aiChunkId)
    }

    func testIdempotentTurnStart() {
        let store = TurnAnchorStore()
        store.recordTurnStart(userChunkId: "u1", terminalRow: 100)
        store.recordTurnStart(userChunkId: "u1", terminalRow: 200) // no-op
        XCTAssertEqual(store.anchor(forChunkId: "u1")?.terminalRowAtSubmit, 100)
    }

    func testPairAIChunk() {
        let store = TurnAnchorStore()
        store.recordTurnStart(userChunkId: "u1", terminalRow: 100)
        store.pairAIChunk(userChunkId: "u1", aiChunkId: "a1")
        let anchor = store.anchor(forChunkId: "u1")
        XCTAssertEqual(anchor?.aiChunkId, "a1")
        // Lookup by AI chunk id should also resolve to the same anchor.
        XCTAssertEqual(store.anchor(forChunkId: "a1")?.userChunkId, "u1")
    }

    func testPairAIChunkIdempotent() {
        let store = TurnAnchorStore()
        store.recordTurnStart(userChunkId: "u1", terminalRow: 100)
        store.pairAIChunk(userChunkId: "u1", aiChunkId: "a1")
        store.pairAIChunk(userChunkId: "u1", aiChunkId: "a2") // ignored
        XCTAssertEqual(store.anchor(forChunkId: "u1")?.aiChunkId, "a1")
    }

    func testAnchorContainingRow() {
        let store = TurnAnchorStore()
        store.recordTurnStart(userChunkId: "u1", terminalRow: 100)
        store.recordTurnStart(userChunkId: "u2", terminalRow: 250)
        store.recordTurnStart(userChunkId: "u3", terminalRow: 400)

        XCTAssertEqual(store.anchorContaining(row: 50)?.userChunkId, nil) // before first
        XCTAssertEqual(store.anchorContaining(row: 100)?.userChunkId, "u1")
        XCTAssertEqual(store.anchorContaining(row: 200)?.userChunkId, "u1")
        XCTAssertEqual(store.anchorContaining(row: 250)?.userChunkId, "u2")
        XCTAssertEqual(store.anchorContaining(row: 399)?.userChunkId, "u2")
        XCTAssertEqual(store.anchorContaining(row: 400)?.userChunkId, "u3")
        XCTAssertEqual(store.anchorContaining(row: 1_000)?.userChunkId, "u3") // after last
    }

    func testSetSurfaceClearsAnchors() {
        let store = TurnAnchorStore()
        let workspace = UUID()
        let surface1 = UUID()
        let surface2 = UUID()
        store.setSurface(workspaceId: workspace, surfaceId: surface1)
        store.recordTurnStart(userChunkId: "u1", terminalRow: 100)
        XCTAssertEqual(store.orderedAnchors.count, 1)

        // Same surface — no clear.
        store.setSurface(workspaceId: workspace, surfaceId: surface1)
        XCTAssertEqual(store.orderedAnchors.count, 1)

        // Different surface — clears.
        store.setSurface(workspaceId: workspace, surfaceId: surface2)
        XCTAssertEqual(store.orderedAnchors.count, 0)
        XCTAssertNil(store.anchor(forChunkId: "u1"))
    }

    func testOrderedAnchorsPreservesInsertionOrder() {
        let store = TurnAnchorStore()
        store.recordTurnStart(userChunkId: "z", terminalRow: 100)
        store.recordTurnStart(userChunkId: "a", terminalRow: 200)
        store.recordTurnStart(userChunkId: "m", terminalRow: 300)
        XCTAssertEqual(store.orderedAnchors.map(\.userChunkId), ["z", "a", "m"])
    }
}
