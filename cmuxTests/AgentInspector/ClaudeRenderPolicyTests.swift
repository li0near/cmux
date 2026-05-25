import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Decision-table tests for `ClaudeRenderPolicy.route(_:)`.
final class ClaudeRenderPolicyTests: XCTestCase {

    private let activeBranch: Set<String> = []

    func testSessionOrphanMetadataSkips() {
        for type in ["permission-mode", "agent-name", "custom-title", "queue-operation", "file-history-snapshot"] {
            let line = ClaudeJSONLLine(type: type)
            let r = ClaudeRenderPolicy.route(line, activeBranch: activeBranch, activeBranchAvailable: false)
            XCTAssertEqual(r, .skip, "type=\(type) should skip")
        }
    }

    func testLastPromptSkips() {
        let line = ClaudeJSONLLine(type: "last-prompt", leafUuid: "x")
        XCTAssertEqual(ClaudeRenderPolicy.route(line, activeBranch: [], activeBranchAvailable: true), .skip)
    }

    func testProgressSkips() {
        let line = ClaudeJSONLLine(type: "progress", uuid: "p1")
        XCTAssertEqual(ClaudeRenderPolicy.route(line, activeBranch: [], activeBranchAvailable: false), .skip)
    }

    func testPrLinkRendersSpecial() {
        let line = ClaudeJSONLLine(
            type: "pr-link",
            prNumber: 1, prUrl: "u", prRepository: "r"
        )
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: [], activeBranchAvailable: false),
            .renderSpecial(.prLink)
        )
    }

    func testSystemSubtypeTurnDurationSkips() {
        let line = ClaudeJSONLLine(type: "system", uuid: "s1", parentUuid: "x", subtype: "turn_duration", durationMs: 1000)
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["s1"], activeBranchAvailable: true),
            .skip
        )
    }

    func testSystemSubtypeAwaySummaryRendersRecap() {
        let line = ClaudeJSONLLine(type: "system", uuid: "s1", parentUuid: "x", subtype: "away_summary", content: "hi")
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["s1"], activeBranchAvailable: true),
            .renderSpecial(.recap)
        )
    }

    func testSystemSubtypeCompactBoundaryRendersCompact() {
        let line = ClaudeJSONLLine(type: "system", uuid: "s1", parentUuid: "x", subtype: "compact_boundary", content: "summary")
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["s1"], activeBranchAvailable: true),
            .render(.compact)
        )
    }

    func testSidechainAlwaysRoutesToSidechainPool() {
        let line = ClaudeJSONLLine(
            type: "assistant", uuid: "side1", parentUuid: "p", isSidechain: true,
            parentToolUseID: "task1"
        )
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["side1"], activeBranchAvailable: true),
            .sidechainMain
        )
    }

    func testTreeAffiliatedOnActiveBranchRendersUser() {
        let line = ClaudeJSONLLine(
            type: "user", uuid: "u1", parentUuid: nil, isMeta: false
        )
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["u1"], activeBranchAvailable: true),
            .render(.user)
        )
    }

    func testTreeAffiliatedNotOnActiveBranchSkipsAsAbandoned() {
        let line = ClaudeJSONLLine(
            type: "user", uuid: "u-abandoned", parentUuid: "u1"
        )
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["u1"], activeBranchAvailable: true),
            .skipBranchAffiliated
        )
    }

    func testToolResultUserLineFoldsIntoAI() {
        // isMeta=true with tool_result block must route to .render(.ai)
        // so the parent tool call gets its result attached.
        let blocks = [
            ClaudeContentBlock(
                type: "tool_result", text: nil, thinking: nil,
                id: nil, name: nil, input: nil,
                toolUseId: "t1", toolResultContent: .string("ok"), isError: false
            )
        ]
        let msg = ClaudeMessage(role: "user", model: nil, content: .blocks(blocks), stopReason: nil)
        let line = ClaudeJSONLLine(
            type: "user", uuid: "tr1", parentUuid: "a1",
            isMeta: true, message: msg
        )
        XCTAssertEqual(
            ClaudeRenderPolicy.route(line, activeBranch: ["tr1"], activeBranchAvailable: true),
            .render(.ai)
        )
    }
}
