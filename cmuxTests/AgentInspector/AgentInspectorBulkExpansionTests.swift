import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the snap-back-first bulk-expansion semantics that ship
/// in the inspector: stage advance, terminal-stage no-op, and
/// direction-aware snap-back when the user has manually fiddled
/// rows in the opposite direction. These are pure functions on
/// `AgentInspectorPanel.ExpansionOverrides` so the panel doesn't
/// need to be instantiated.
final class AgentInspectorBulkExpansionTests: XCTestCase {

    typealias Stage = AgentInspectorPanel.BulkExpansionStage
    typealias Overrides = AgentInspectorPanel.ExpansionOverrides
    typealias Outcome = AgentInspectorPanel.BulkOutcome

    // MARK: - ExpansionOverrides invariants

    func testEmptyOverridesAreEmpty() {
        let o = Overrides()
        XCTAssertTrue(o.isEmpty)
        XCTAssertFalse(o.hasExpandFiddle)
        XCTAssertFalse(o.hasCollapseFiddle)
    }

    func testSetOffDefaultStoresEntry() {
        var o = Overrides()
        // At `topLevelExpanded`, the default for a tool is `false`.
        // Setting it to `true` is an "expand fiddle" — store it.
        o.set(key: "tool:abc", value: true, defaultValue: false)
        XCTAssertFalse(o.isEmpty)
        XCTAssertTrue(o.hasExpandFiddle)
        XCTAssertFalse(o.hasCollapseFiddle)
        XCTAssertTrue(o.value(forKey: "tool:abc", default: false))
    }

    func testSetOnDefaultDropsEntry() {
        var o = Overrides()
        // First store an off-default entry, then revert it.
        o.set(key: "tool:abc", value: true, defaultValue: false)
        XCTAssertFalse(o.isEmpty)
        // Now revert to default — should drop the entry, not keep it.
        o.set(key: "tool:abc", value: false, defaultValue: false)
        XCTAssertTrue(o.isEmpty)
        XCTAssertFalse(o.hasExpandFiddle)
    }

    func testCollapseFiddleDetected() {
        var o = Overrides()
        // At `topLevelExpanded`, the default for the AI header is `true`.
        // Setting it to `false` is a "collapse fiddle".
        o.set(key: "ai:xyz", value: false, defaultValue: true)
        XCTAssertTrue(o.hasCollapseFiddle)
        XCTAssertFalse(o.hasExpandFiddle)
    }

    func testMixedFiddleDirections() {
        var o = Overrides()
        o.set(key: "tool:t1", value: true, defaultValue: false)   // expand fiddle
        o.set(key: "ai:a1", value: false, defaultValue: true)     // collapse fiddle
        XCTAssertTrue(o.hasExpandFiddle)
        XCTAssertTrue(o.hasCollapseFiddle)
    }

    func testClearEmptiesEverything() {
        var o = Overrides()
        o.set(key: "tool:t1", value: true, defaultValue: false)
        o.set(key: "ai:a1", value: false, defaultValue: true)
        o.clear()
        XCTAssertTrue(o.isEmpty)
        XCTAssertFalse(o.hasExpandFiddle)
        XCTAssertFalse(o.hasCollapseFiddle)
    }

    // MARK: - collapseOutcome — clean (no overrides)

    func testCollapseFromFullyExpandedAdvancesToTopLevel() {
        let outcome = Overrides.collapseOutcome(stage: .fullyExpanded, overrides: Overrides())
        XCTAssertEqual(outcome, .advance(to: .topLevelExpanded))
    }

    func testCollapseFromTopLevelAdvancesToFullyCollapsed() {
        let outcome = Overrides.collapseOutcome(stage: .topLevelExpanded, overrides: Overrides())
        XCTAssertEqual(outcome, .advance(to: .fullyCollapsed))
    }

    func testCollapseAtTerminalIsNoop() {
        let outcome = Overrides.collapseOutcome(stage: .fullyCollapsed, overrides: Overrides())
        XCTAssertEqual(outcome, .noop)
    }

    // MARK: - collapseOutcome — snap-back

    func testCollapseWithExpandFiddleSnapsBack() {
        var o = Overrides()
        o.set(key: "tool:abc", value: true, defaultValue: false)
        let outcome = Overrides.collapseOutcome(stage: .topLevelExpanded, overrides: o)
        XCTAssertEqual(outcome, .snapBack)
    }

    func testCollapseAtTerminalWithExpandFiddleSnapsBack() {
        // At fullyCollapsed, the user manually expanded a sub-item
        // (set true while the default was false). Click Collapse —
        // should snap back to close that override even though the
        // stage is already terminal.
        var o = Overrides()
        o.set(key: "tool:abc", value: true, defaultValue: false)
        let outcome = Overrides.collapseOutcome(stage: .fullyCollapsed, overrides: o)
        XCTAssertEqual(outcome, .snapBack)
    }

    func testCollapseWithCollapseFiddleAdvances() {
        // The user fiddled in the COLLAPSE direction. Clicking
        // Collapse advances normally — same direction, no snap-back.
        var o = Overrides()
        o.set(key: "ai:xyz", value: false, defaultValue: true)
        let outcome = Overrides.collapseOutcome(stage: .topLevelExpanded, overrides: o)
        XCTAssertEqual(outcome, .advance(to: .fullyCollapsed))
    }

    // MARK: - expandOutcome — clean (no overrides)

    func testExpandFromFullyCollapsedAdvancesToTopLevel() {
        let outcome = Overrides.expandOutcome(stage: .fullyCollapsed, overrides: Overrides())
        XCTAssertEqual(outcome, .advance(to: .topLevelExpanded))
    }

    func testExpandFromTopLevelAdvancesToFullyExpanded() {
        let outcome = Overrides.expandOutcome(stage: .topLevelExpanded, overrides: Overrides())
        XCTAssertEqual(outcome, .advance(to: .fullyExpanded))
    }

    func testExpandAtTerminalIsNoop() {
        let outcome = Overrides.expandOutcome(stage: .fullyExpanded, overrides: Overrides())
        XCTAssertEqual(outcome, .noop)
    }

    // MARK: - expandOutcome — snap-back

    func testExpandWithCollapseFiddleSnapsBack() {
        var o = Overrides()
        o.set(key: "ai:xyz", value: false, defaultValue: true)
        let outcome = Overrides.expandOutcome(stage: .topLevelExpanded, overrides: o)
        XCTAssertEqual(outcome, .snapBack)
    }

    func testExpandWithExpandFiddleAdvances() {
        // Regression test for the user-reported bug: at topLevel,
        // user manually expanded a sub-item (above-default fiddle).
        // Click Expand → MUST advance directly to fullyExpanded.
        // The pre-fix symmetric semantics would snap-back here,
        // closing the user's expansion (perceived as "expand
        // collapsed me").
        var o = Overrides()
        o.set(key: "tool:abc", value: true, defaultValue: false)
        let outcome = Overrides.expandOutcome(stage: .topLevelExpanded, overrides: o)
        XCTAssertEqual(outcome, .advance(to: .fullyExpanded))
    }

    func testExpandAtTerminalWithCollapseFiddleSnapsBack() {
        // Symmetric of testCollapseAtTerminalWithExpandFiddleSnapsBack.
        var o = Overrides()
        o.set(key: "ai:xyz", value: false, defaultValue: true)
        let outcome = Overrides.expandOutcome(stage: .fullyExpanded, overrides: o)
        XCTAssertEqual(outcome, .snapBack)
    }

    // MARK: - ExpansionResolver integration via ChunkRowSnapshot.from

    /// Build a resolver that consults a captured override dict + stage,
    /// matching the panel view's wiring at runtime.
    private func makeResolver(
        stage: Stage,
        overrides: Overrides
    ) -> ChunkRowSnapshot.ExpansionResolver {
        ChunkRowSnapshot.ExpansionResolver(
            chunkBodyOpen: { id in
                overrides.value(forKey: "chunk:\(id)", default: stage == .fullyExpanded)
            },
            aiHeaderOpen: { id in
                overrides.value(forKey: "ai:\(id)", default: stage != .fullyCollapsed)
            },
            thinkingOpen: { id in
                overrides.value(forKey: "thinking:\(id)", default: stage == .fullyExpanded)
            },
            toolExpanded: { id in
                overrides.value(forKey: "tool:\(id)", default: stage == .fullyExpanded)
            }
        )
    }

    private func makeAI(
        id: String = "a1",
        assistantText: String = "hello",
        thinkingText: String = "",
        toolCalls: [AgentToolCall] = []
    ) -> AgentChunk {
        .ai(AIChunk(
            id: id,
            assistantText: assistantText,
            thinkingText: thinkingText,
            toolCalls: toolCalls,
            model: nil,
            startTime: Date()
        ))
    }

    func testResolverDefaultsAtTopLevel() {
        let resolver = makeResolver(stage: .topLevelExpanded, overrides: Overrides())
        let user = AgentChunk.user(UserChunk(id: "u1", text: "hi", startTime: Date()))
        let userSnapshot = ChunkRowSnapshot.from(user, expansion: resolver)
        XCTAssertFalse(userSnapshot.chunkBodyOpen, "User body should be closed at topLevel")

        let aiSnapshot = ChunkRowSnapshot.from(makeAI(), expansion: resolver)
        XCTAssertTrue(aiSnapshot.aiHeaderOpen, "AI header should be open at topLevel")
        XCTAssertFalse(aiSnapshot.thinkingOpen, "Thinking should be closed at topLevel")
    }

    func testResolverDefaultsAtFullyCollapsed() {
        let resolver = makeResolver(stage: .fullyCollapsed, overrides: Overrides())
        let aiSnapshot = ChunkRowSnapshot.from(makeAI(), expansion: resolver)
        XCTAssertFalse(aiSnapshot.aiHeaderOpen, "AI header should be closed at fullyCollapsed")
        XCTAssertFalse(aiSnapshot.thinkingOpen, "Thinking should be closed at fullyCollapsed")
    }

    func testResolverDefaultsAtFullyExpanded() {
        let resolver = makeResolver(stage: .fullyExpanded, overrides: Overrides())
        let aiSnapshot = ChunkRowSnapshot.from(
            makeAI(thinkingText: "weighing options"),
            expansion: resolver
        )
        XCTAssertTrue(aiSnapshot.aiHeaderOpen, "AI header should be open at fullyExpanded")
        XCTAssertTrue(aiSnapshot.thinkingOpen, "Thinking should be open at fullyExpanded")
    }

    func testResolverHonorsOverride() {
        var o = Overrides()
        // At topLevel, AI header default is true. Override to false:
        // a collapse-direction fiddle on the AI header.
        o.set(key: "ai:a1", value: false, defaultValue: true)
        let resolver = makeResolver(stage: .topLevelExpanded, overrides: o)
        let aiSnapshot = ChunkRowSnapshot.from(makeAI(), expansion: resolver)
        XCTAssertFalse(aiSnapshot.aiHeaderOpen, "Override should win over the bulk default")
    }

    func testResolverThinkingClampedToNilWhenNoThinkingText() {
        // At fullyExpanded, the resolver default for thinking is true.
        // But when the AI chunk has no thinking content, the snapshot's
        // `thinkingOpen` must be false — there's nothing to open.
        let resolver = makeResolver(stage: .fullyExpanded, overrides: Overrides())
        let aiSnapshot = ChunkRowSnapshot.from(
            makeAI(assistantText: "tool-only response"),
            expansion: resolver
        )
        XCTAssertFalse(aiSnapshot.thinkingOpen, "thinkingOpen must be false when no thinking content exists")
        XCTAssertNil(aiSnapshot.thinking)
    }

    func testResolverPerToolExpansion() {
        var o = Overrides()
        // At topLevel, tool default is false. Override one tool to true.
        o.set(key: "tool:t1", value: true, defaultValue: false)
        let resolver = makeResolver(stage: .topLevelExpanded, overrides: o)
        let ai = makeAI(toolCalls: [
            AgentToolCall(
                id: "t1",
                name: "Bash",
                summary: "",
                inputDetail: "",
                result: nil,
                isError: false
            ),
            AgentToolCall(
                id: "t2",
                name: "Read",
                summary: "",
                inputDetail: "",
                result: nil,
                isError: false
            )
        ])
        let snapshot = ChunkRowSnapshot.from(ai, expansion: resolver)
        XCTAssertEqual(snapshot.toolCalls.count, 2)
        let t1 = snapshot.toolCalls.first { $0.id == "t1" }
        let t2 = snapshot.toolCalls.first { $0.id == "t2" }
        XCTAssertTrue(t1?.expanded ?? false, "Overridden tool should be expanded")
        XCTAssertFalse(t2?.expanded ?? true, "Non-overridden tool should follow default (false at topLevel)")
    }

    // MARK: - toggleExpansion key + default derivation

    /// Verify that `ExpansionOverrides.set(...)` paired with the same
    /// key/default conventions used by `AgentInspectorPanel.toggleExpansion(_:)`
    /// produces the expected dict invariant. This covers the
    /// panel-level toggle without instantiating the panel (which is
    /// `@MainActor` and bound to `Workspace`).
    func testToggleAddsOffDefaultEntry() {
        var o = Overrides()
        // Simulating: at topLevelExpanded, user clicks a tool header.
        // tool default is false; toggle flips to true.
        let key = "tool:t1"
        let defaultValue = false  // stage == fullyExpanded ? true : false
        let current = o.value(forKey: key, default: defaultValue)
        XCTAssertEqual(current, false, "Initial should match default")
        o.set(key: key, value: !current, defaultValue: defaultValue)
        XCTAssertTrue(o.hasExpandFiddle)
    }

    func testToggleRevertsToDefaultDropsEntry() {
        var o = Overrides()
        let key = "tool:t1"
        let defaultValue = false
        // First toggle: away from default.
        o.set(key: key, value: true, defaultValue: defaultValue)
        XCTAssertFalse(o.isEmpty)
        // Second toggle: back to default.
        let current = o.value(forKey: key, default: defaultValue)
        o.set(key: key, value: !current, defaultValue: defaultValue)
        XCTAssertTrue(o.isEmpty, "Reverting to default must drop the entry, not store a duplicate")
        XCTAssertFalse(o.hasExpandFiddle)
    }
}
