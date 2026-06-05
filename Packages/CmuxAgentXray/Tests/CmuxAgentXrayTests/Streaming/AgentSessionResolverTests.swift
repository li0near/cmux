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
        hookRecords: [Int32: AgentHookSessionMatch] = [:],
        restoredSnapshots: [UUID: RestoredAgentSnapshot] = [:],
        claudeProjectsRoot: String = "/Users/test/.claude/projects"
    ) -> AgentSessionResolver {
        AgentSessionResolver(
            agentPIDsForPanel: { panelID in pidsForPanel[panelID] ?? [] },
            hookRecordForPID: { pid in hookRecords[pid] },
            restoredSnapshotForPanel: { panelID in restoredSnapshots[panelID] },
            claudeProjectsRoot: claudeProjectsRoot
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

    @Test("Hook record without transcriptPath → resolver returns nil (regression)")
    func hookRecordWithoutTranscriptPath() {
        // Regression repro: claude's SessionStart hook fires immediately
        // when claude starts (bare `claude`, no `--resume`, no prompt
        // yet). The hook record is written with sessionID + cwd + pid,
        // but `transcriptPath` is nil/empty (claude hasn't created or
        // disclosed the .jsonl path yet). If the resolver returns a
        // session for this incomplete record, `TranscriptStream.attach`
        // early-returns because the path is empty, leaving the panel
        // "Hooked" (resolvedSession != nil) with NO `JSONLTail`
        // watching anything. When the user sends the first prompt and
        // claude appends to the .jsonl, nothing observes the file —
        // the panel stays empty even after the writes.
        //
        // Correct behaviour (pre-Phase 18): treat the record as not
        // yet ready, return nil. The panel stays detached until the
        // hook record's next update (e.g. prompt-submit) populates
        // `transcriptPath`; the store watcher then fires another
        // recompute and the panel hooks + streams cleanly.
        let pid: Int32 = 12345
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SESSION-NO-PATH",
                    cwd: "/Users/test/myproject",
                    transcriptPath: nil
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved == nil)
    }

    @Test("Hook record with empty transcriptPath → resolver returns nil")
    func hookRecordWithEmptyTranscriptPath() {
        let pid: Int32 = 12345
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SESSION-EMPTY-PATH",
                    cwd: "/x",
                    transcriptPath: ""
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved == nil)
    }

    @Test("Skips PIDs whose record has nil transcriptPath, returns first usable one")
    func skipsRecordsWithoutTranscriptPath() {
        let firstPID: Int32 = 11111
        let secondPID: Int32 = 22222
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [firstPID, secondPID]],
            hookRecords: [
                firstPID: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "FIRST-NO-PATH",
                    cwd: "/x",
                    transcriptPath: nil  // SessionStart raced ahead of path discovery
                ),
                secondPID: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SECOND-WITH-PATH",
                    cwd: "/x",
                    transcriptPath: "/x/SECOND-WITH-PATH.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.sessionID == "SECOND-WITH-PATH")
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

    // MARK: - Path 1: restored snapshot synthesis

    @Test("Restored snapshot resolves immediately, even before any agent PID exists")
    func restoredSnapshotResolvesPreSpawn() {
        // Auto-resume scenario: panel restored, agent process not yet
        // spawned. Snapshot synthesizes a session; transcriptPath
        // points at the (not-yet-existing) Claude transcript file.
        let resolver = makeResolver(
            pidsForPanel: [:],  // no PIDs registered yet
            hookRecords: [:],
            restoredSnapshots: [
                Self.testPanelID: RestoredAgentSnapshot(
                    agentKind: .claude,
                    sessionID: "SESSION-RESTORED",
                    workingDirectory: "/Users/test/myproject"
                )
            ]
        )

        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.agentKind == .claude)
        #expect(resolved?.sessionID == "SESSION-RESTORED")
        #expect(resolved?.cwd == "/Users/test/myproject")
        #expect(resolved?.transcriptPath ==
            "/Users/test/.claude/projects/-Users-test-myproject/SESSION-RESTORED.jsonl")
    }

    @Test("Path 1 wins over path 2 when both available")
    func snapshotTakesPrecedenceOverHookRecord() {
        // Edge case: snapshot says session A, hook record says
        // session B. cmux's snapshot is the canonical "what was
        // restored" source; path 2 is for fresh / live cases.
        let pid: Int32 = 12345
        let resolver = makeResolver(
            pidsForPanel: [Self.testPanelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SESSION-FROM-HOOK",
                    cwd: "/x",
                    transcriptPath: "/x/SESSION-FROM-HOOK.jsonl"
                )
            ],
            restoredSnapshots: [
                Self.testPanelID: RestoredAgentSnapshot(
                    agentKind: .claude,
                    sessionID: "SESSION-FROM-SNAPSHOT",
                    workingDirectory: "/Users/test/myproject"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.sessionID == "SESSION-FROM-SNAPSHOT")
    }

    @Test("Codex snapshot resolves with nil transcriptPath (date-bucketed layout)")
    func codexSnapshotNilTranscript() {
        let resolver = makeResolver(
            restoredSnapshots: [
                Self.testPanelID: RestoredAgentSnapshot(
                    agentKind: .codex,
                    sessionID: "CODEX-RESTORED",
                    workingDirectory: "/x"
                )
            ]
        )
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved?.agentKind == .codex)
        #expect(resolved?.sessionID == "CODEX-RESTORED")
        #expect(resolved?.transcriptPath == nil)
    }

    @Test("No snapshot, no PIDs → falls through to nil")
    func noSnapshotNoPIDs() {
        let resolver = makeResolver()
        let resolved = resolver.resolve(
            panelID: Self.testPanelID,
            workspaceID: Self.testWorkspaceID
        )
        #expect(resolved == nil)
    }
}
