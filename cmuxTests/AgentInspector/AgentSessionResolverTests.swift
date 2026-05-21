import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies AgentSessionResolver behavior. The resolver intentionally has
/// no disk-mtime fallback — when no live process and no hook record can be
/// found, it returns nil rather than guessing the freshest jsonl in the
/// shared cwd (which would collapse N concurrent sessions to 1).
final class AgentSessionResolverTests: XCTestCase {

    func testReturnsNilWhenNoHookRecordAndNoLiveProcess() {
        let resolver = AgentSessionResolver(
            claudeStore: ClaudeHookSessionStore(
                path: "/tmp/missing-claude-\(UUID().uuidString).json"
            ),
            codexStore: CodexHookSessionStore(
                path: "/tmp/missing-codex-\(UUID().uuidString).json"
            )
        )
        XCTAssertNil(
            resolver.resolve(
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwdHint: "/Users/test/work-area"
            )
        )
    }

    func testReturnsNilWhenCwdHintIsEmpty() {
        let resolver = AgentSessionResolver(
            claudeStore: ClaudeHookSessionStore(
                path: "/tmp/missing-claude-\(UUID().uuidString).json"
            ),
            codexStore: CodexHookSessionStore(
                path: "/tmp/missing-codex-\(UUID().uuidString).json"
            )
        )
        XCTAssertNil(
            resolver.resolve(
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwdHint: nil
            )
        )
        XCTAssertNil(
            resolver.resolve(
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwdHint: ""
            )
        )
    }
}
