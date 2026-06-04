import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("AgentSessionResolver — live process inspection")
struct AgentSessionResolverTests {

    private static let testCwd = "/Users/test/myproject"
    private static let testWorkspaceID = "WORKSPACE-ABC"
    private static let testSurfaceID = "SURFACE-XYZ"

    private func makeResolver(_ processes: [AgentProcessSnapshot]) -> AgentSessionResolver {
        AgentSessionResolver(
            listAgentProcesses: { processes }
        )
    }

    // MARK: - Post-restart attach

    @Test("Resolves the session via live PID inspection — workspaceID/TTY irrelevant")
    func livePostRestartResolve() {
        // Scenario: cmux restarts; the panel's workspace has a fresh
        // UUID. No hook records match the new UUID. But a claude
        // process is running in the panel's cwd with an open .jsonl —
        // the live inspection path picks it up.
        let processes = [
            AgentProcessSnapshot(
                pid: 12345,
                agentKind: .claude,
                cwd: Self.testCwd,
                openTranscripts: ["/Users/test/.claude/projects/-Users-test-myproject/SESSION-LIVE.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: "FRESH-WORKSPACE-AFTER-RESTART",
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved?.agentKind == .claude)
        #expect(resolved?.sessionID == "SESSION-LIVE")
        #expect(resolved?.transcriptPath == "/Users/test/.claude/projects/-Users-test-myproject/SESSION-LIVE.jsonl")
        #expect(resolved?.cwd == Self.testCwd)
        #expect(resolved?.workspaceID == "FRESH-WORKSPACE-AFTER-RESTART")
        #expect(resolved?.surfaceID == Self.testSurfaceID)
    }

    // MARK: - /new mid-session

    @Test("/new mid-session: same PID, new open fd, returns new sessionId")
    func newMidSession() {
        // Scenario: user typed /new inside a running claude. The
        // process is the same PID (claude doesn't spawn a new
        // process for /new), but it has closed the old transcript and
        // opened a new one. argv-scraping would still see the old
        // --resume id; the live-fd path returns the truth.
        let processes = [
            AgentProcessSnapshot(
                pid: 12345,
                agentKind: .claude,
                cwd: Self.testCwd,
                openTranscripts: ["/Users/test/.claude/projects/-Users-test-myproject/SESSION-NEW-AFTER-SLASHNEW.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved?.sessionID == "SESSION-NEW-AFTER-SLASHNEW")
    }

    // MARK: - Codex

    @Test("Codex sessions are resolved with .codex agent kind")
    func codex() {
        let processes = [
            AgentProcessSnapshot(
                pid: 9999,
                agentKind: .codex,
                cwd: Self.testCwd,
                openTranscripts: ["/Users/test/.codex/sessions/2026/06/05/CODEX-SESS.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved?.agentKind == .codex)
        #expect(resolved?.sessionID == "CODEX-SESS")
    }

    // MARK: - Cwd mismatch

    @Test("Returns nil when the panel's cwd doesn't match any running process")
    func cwdMismatch() {
        let processes = [
            AgentProcessSnapshot(
                pid: 12345,
                agentKind: .claude,
                cwd: "/Users/test/some-other-project",
                openTranscripts: ["/Users/test/.claude/projects/x/Y.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved == nil)
    }

    @Test("Returns nil when no agent processes are running at all")
    func noAgentProcesses() {
        let resolver = makeResolver([])

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved == nil)
    }

    @Test("Returns nil when cwdHint is nil")
    func nilCwd() {
        let processes = [
            AgentProcessSnapshot(
                pid: 12345,
                agentKind: .claude,
                cwd: Self.testCwd,
                openTranscripts: ["/Users/test/.claude/projects/x/Y.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: nil
        )

        #expect(resolved == nil)
    }

    // MARK: - Ambiguous matches

    @Test("Multiple agents in the same cwd → returns nil (no guessing)")
    func ambiguousMultipleAgents() {
        let processes = [
            AgentProcessSnapshot(
                pid: 11111,
                agentKind: .claude,
                cwd: Self.testCwd,
                openTranscripts: ["/Users/test/.claude/projects/x/A.jsonl"]
            ),
            AgentProcessSnapshot(
                pid: 22222,
                agentKind: .claude,
                cwd: Self.testCwd,
                openTranscripts: ["/Users/test/.claude/projects/x/B.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved == nil)
    }

    // MARK: - Multiple open fds (rare; transient during /new)

    @Test("Process with no open transcripts returns nil")
    func noOpenTranscripts() {
        let processes = [
            AgentProcessSnapshot(
                pid: 12345,
                agentKind: .claude,
                cwd: Self.testCwd,
                openTranscripts: []
            )
        ]
        let resolver = makeResolver(processes)

        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: Self.testCwd
        )

        #expect(resolved == nil)
    }

    // MARK: - Cwd normalization

    @Test("Trailing slashes / standardizingPath normalization works")
    func cwdNormalization() {
        let processes = [
            AgentProcessSnapshot(
                pid: 12345,
                agentKind: .claude,
                cwd: "/Users/test/myproject/",  // trailing slash
                openTranscripts: ["/Users/test/.claude/projects/x/Z.jsonl"]
            )
        ]
        let resolver = makeResolver(processes)

        // Caller passes the canonical form (no trailing slash).
        let resolved = resolver.resolve(
            workspaceID: Self.testWorkspaceID,
            surfaceID: Self.testSurfaceID,
            cwdHint: "/Users/test/myproject"
        )

        #expect(resolved?.sessionID == "Z")
    }
}
