import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-data tests for `ClaudeBranchResolver` — the active-branch tree walk
/// and abandoned-branch grouping driven by `last-prompt` markers.
final class ClaudeBranchResolverTests: XCTestCase {

    // MARK: - Fixture helper (matches ClaudeChunkBuilderTests.decodeFixture)

    private func decodeFixture(_ name: String) throws -> [ClaudeJSONLLine] {
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

    // MARK: - No-rewind degenerate case

    func testNoLastPromptMarkerTreatsAllUUIDsAsActive() {
        let lines = [
            ClaudeJSONLLine(type: "user", uuid: "u1", parentUuid: nil),
            ClaudeJSONLLine(type: "assistant", uuid: "a1", parentUuid: "u1"),
        ]
        let r = ClaudeBranchResolver.resolve(lines: lines)
        XCTAssertNil(r.leafUuid)
        XCTAssertEqual(r.activeUUIDs, ["u1", "a1"])
        XCTAssertEqual(r.totalRewinds, 0)
        XCTAssertTrue(r.abandonedBranches.isEmpty)
    }

    // MARK: - Rewind tree fixture

    func testRewindTreeFixtureGroupsAbandonedBranches() throws {
        let lines = try decodeFixture("claude-rewind-tree")
        let r = ClaudeBranchResolver.resolve(lines: lines)

        XCTAssertEqual(r.leafUuid, "a-active")
        XCTAssertEqual(r.activeUUIDs, ["u-root", "u-active", "a-active"])
        // Two abandoned branches diverge from u-root: a-attempt1 (1 chunk),
        // and u-attempt2 (with its child a-attempt2 = 2 chunks).
        XCTAssertEqual(r.totalRewinds, 2)

        let branches = r.abandonedBranches
        XCTAssertEqual(branches.map(\.branchRootUuid).sorted(), ["a-attempt1", "u-attempt2"])
        for branch in branches {
            XCTAssertEqual(branch.divergencePointUuid, "u-root")
            switch branch.branchRootUuid {
            case "a-attempt1": XCTAssertEqual(branch.chunkCount, 1)
            case "u-attempt2": XCTAssertEqual(branch.chunkCount, 2)
            default: XCTFail("unexpected branch root \(branch.branchRootUuid)")
            }
        }
    }

    // MARK: - Corrupt leaf falls back to all-active

    func testLeafUuidNotInLinesFallsBackToAllActive() {
        let lines = [
            ClaudeJSONLLine(type: "user", uuid: "u1", parentUuid: nil),
            ClaudeJSONLLine(type: "last-prompt", leafUuid: "missing-uuid"),
        ]
        let r = ClaudeBranchResolver.resolve(lines: lines)
        // Falls back: active set covers every UUID, no abandoned branches.
        XCTAssertEqual(r.activeUUIDs, ["u1"])
        XCTAssertTrue(r.abandonedBranches.isEmpty)
    }

    // MARK: - Latest last-prompt wins

    func testMultipleLastPromptMarkersPickLatest() {
        let lines = [
            ClaudeJSONLLine(type: "user", uuid: "u1", parentUuid: nil),
            ClaudeJSONLLine(type: "assistant", uuid: "a1", parentUuid: "u1"),
            ClaudeJSONLLine(type: "last-prompt", leafUuid: "u1"),
            ClaudeJSONLLine(type: "last-prompt", leafUuid: "a1"),
        ]
        let r = ClaudeBranchResolver.resolve(lines: lines)
        XCTAssertEqual(r.leafUuid, "a1")
        XCTAssertEqual(r.activeUUIDs, ["u1", "a1"])
    }
}
