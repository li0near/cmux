import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies that `ClaudeHookSessionStore` correctly parses
/// `~/.cmuxterm/claude-hook-sessions.json` and resolves
/// `(workspaceId, surfaceId)` to a record.
final class ClaudeHookSessionStoreTests: XCTestCase {

    private func fixturePath() -> String {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: "claude-hook-sessions", withExtension: "json") {
            return url.path
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentInspector/claude-hook-sessions.json")
            .path
    }

    func testLoadAllParsesAllRecords() {
        let store = ClaudeHookSessionStore(path: fixturePath())
        let all = store.loadAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertNotNil(all["sess-aaa"])
        XCTAssertEqual(all["sess-aaa"]?.cwd, "/Users/dev/proj")
        XCTAssertEqual(all["sess-aaa"]?.pid, 12345)
        XCTAssertEqual(
            all["sess-aaa"]?.transcriptPath,
            "/Users/dev/.claude/projects/-Users-dev-proj/sess-aaa.jsonl"
        )
    }

    func testRecordForWorkspaceSurfacePicksMostRecent() {
        let store = ClaudeHookSessionStore(path: fixturePath())
        // Two sessions share the same workspace+surface; bbb has updatedAt
        // 1747800200 vs aaa's 1747800100 → bbb should win.
        let resolved = store.record(
            forWorkspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
        XCTAssertEqual(resolved?.sessionId, "sess-bbb")
    }

    func testUnknownSurfaceReturnsNil() {
        let store = ClaudeHookSessionStore(path: fixturePath())
        let resolved = store.record(
            forWorkspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "00000000-0000-0000-0000-000000000000"
        )
        XCTAssertNil(resolved)
    }

    func testMissingFileReturnsEmpty() {
        let store = ClaudeHookSessionStore(path: "/tmp/this-file-does-not-exist.json")
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func testFlatLayoutFallback() throws {
        // Tolerate the legacy flat layout `{ sid: {...} }`.
        let tmp = NSTemporaryDirectory() + "claude-hook-flat-\(UUID().uuidString).json"
        let json: [String: Any] = [
            "sess-flat": [
                "sessionId": "sess-flat",
                "workspaceId": "ws-flat",
                "surfaceId": "sf-flat",
                "cwd": "/x",
                "transcriptPath": "/tmp/flat.jsonl",
                "pid": 999,
                "startedAt": 0,
                "updatedAt": 1,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = ClaudeHookSessionStore(path: tmp)
        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all["sess-flat"]?.transcriptPath, "/tmp/flat.jsonl")
    }
}
