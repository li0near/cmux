import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("AgentSessionResolver — single source: PID → hook record")
@MainActor
struct AgentSessionResolverTests {

    private static let testPanelID = UUID()
    private static let testWorkspaceID = "WORKSPACE-ABC"

    private func makeResolver(
        pidsForPanel: [UUID: [Int32]] = [:],
        hookRecords: [Int32: AgentHookSessionMatch] = [:]
    ) -> AgentSessionResolver {
        AgentSessionResolver(
            agentPIDsForPanel: { panelID in pidsForPanel[panelID] ?? [] },
            hookRecordForPID: { pid in hookRecords[pid] }
        )
    }

    // MARK: - Happy paths

    @Test("Hook record exists for the panel's registered PID → resolves")
    func basicResolve() {
        let pid: Int32 = 12345
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SESSION-LIVE",
                    cwd: "/Users/test/myproject",
                    transcriptPath: "/Users/test/.claude/projects/-Users-test-myproject/SESSION-LIVE.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.agentKind == .claude)
        #expect(resolved?.sessionID == "SESSION-LIVE")
        #expect(resolved?.transcriptPath == "/Users/test/.claude/projects/-Users-test-myproject/SESSION-LIVE.jsonl")
        #expect(resolved?.workspaceID == Self.testWorkspaceID)
        #expect(resolved?.surfaceID == Self.testPanelID.uuidString)
    }

    @Test("Codex agent kind passes through")
    func codex() {
        let pid: Int32 = 99
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .codex,
                    sessionID: "CODEX-SESS",
                    cwd: "/x",
                    transcriptPath: "/codex/path/CODEX-SESS.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.agentKind == .codex)
        #expect(resolved?.sessionID == "CODEX-SESS")
    }

    // MARK: - /new mid-session

    @Test("/new mid-session: same PID, hook record updated → returns new sessionID")
    func newMidSession() {
        // Pretend the hook record was upserted with the new sessionID.
        // The PID never changed (same claude process; /new is in-process).
        let pid: Int32 = 12345
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SESSION-AFTER-SLASHNEW",
                    cwd: "/proj",
                    transcriptPath: "/x/SESSION-AFTER-SLASHNEW.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.sessionID == "SESSION-AFTER-SLASHNEW")
    }

    // MARK: - Failure modes

    @Test("No PIDs registered for the panel → nil")
    func noPIDs() {
        let resolver = makeResolver(pidsForPanel: [:], hookRecords: [:])
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved == nil)
    }

    @Test("PID registered but hook hasn't fired yet → nil")
    func pidWithoutHookRecord() {
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [12345]],
            hookRecords: [:]  // hook hasn't written a record for this pid yet
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved == nil)
    }

    @Test("Multiple PIDs: first one with a hook record wins")
    func multiplePIDsFirstMatchWins() {
        // Order in [Int32] is the iteration order — first match wins.
        let firstPID: Int32 = 11111
        let secondPID: Int32 = 22222
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [firstPID, secondPID]],
            hookRecords: [
                firstPID: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "FIRST",
                    cwd: "/a",
                    transcriptPath: "/a/FIRST.jsonl"
                ),
                secondPID: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SECOND",
                    cwd: "/a",
                    transcriptPath: "/a/SECOND.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.sessionID == "FIRST")
    }

    @Test("Multiple PIDs: skips ones without records, returns first that matches")
    func multiplePIDsSkipsMissing() {
        let firstPID: Int32 = 11111
        let secondPID: Int32 = 22222
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [firstPID, secondPID]],
            hookRecords: [
                // firstPID has no record (hook hasn't fired for it)
                secondPID: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SECOND",
                    cwd: "/a",
                    transcriptPath: "/a/SECOND.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.sessionID == "SECOND")
    }
}
