import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("AgentSessionResolver — path 3: remote attach via user-supplied id")
@MainActor
struct AgentSessionResolverPath3Tests {

    private static let panelID = UUID()
    private static let workspaceID = "WORKSPACE-XYZ"

    private static let testTransport = SSHTransport(
        destination: "ubuntu@example.com",
        port: 22,
        identityFile: "/Users/test/.ssh/id_ed25519",
        controlPath: "/tmp/cmux-ssh-501-%C"
    )

    private func ctx(remoteHome: String, cwd: String = "/home/ubuntu/myproj") -> RemoteAttachContext {
        RemoteAttachContext(
            sshTransport: Self.testTransport,
            cwd: cwd,
            remoteHome: remoteHome,
            destination: Self.testTransport.destination,
            agentKind: .claude
        )
    }

    private func makeResolver(
        remoteContext: RemoteAttachContext? = nil,
        remoteSession: String? = nil,
        pidsForPanel: [UUID: [Int32]] = [:],
        hookRecords: [Int32: AgentHookSessionMatch] = [:],
        restoredSnapshots: [UUID: RestoredAgentSnapshot] = [:]
    ) -> AgentSessionResolver {
        AgentSessionResolver(
            agentPIDsForPanel: { panelID in pidsForPanel[panelID] ?? [] },
            hookRecordForPID: { pid in hookRecords[pid] },
            restoredSnapshotForPanel: { panelID in restoredSnapshots[panelID] },
            remoteContextForPanel: { _ in remoteContext },
            remoteSessionForPanel: { _, _ in remoteSession }
        )
    }

    // MARK: - Happy path

    @Test("Path 3 synthesizes .remote(_:) when context + session id present")
    func path3HappyPath() {
        let resolver = makeResolver(
            remoteContext: ctx(remoteHome: "/home/ubuntu"),
            remoteSession: "SESSION-REMOTE"
        )
        let resolved = resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID)
        #expect(resolved?.agentKind == .claude)
        #expect(resolved?.sessionID == "SESSION-REMOTE")
        #expect(resolved?.cwd == "/home/ubuntu/myproj")
        // The transcript path encodes cwd by replacing '/' with '-' and
        // is rooted at the *resolved* remote $HOME (no tilde left over).
        #expect(resolved?.transcriptPath == "/home/ubuntu/.claude/projects/-home-ubuntu-myproj/SESSION-REMOTE.jsonl")
        #expect(resolved?.transport == .remote(Self.testTransport))
    }

    @Test("Trailing slash on remoteHome is normalized")
    func remoteHomeTrailingSlash() {
        let resolver = makeResolver(
            remoteContext: ctx(remoteHome: "/home/ubuntu/"),
            remoteSession: "SESSION-REMOTE"
        )
        let resolved = resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID)
        // No double-slash.
        #expect(resolved?.transcriptPath == "/home/ubuntu/.claude/projects/-home-ubuntu-myproj/SESSION-REMOTE.jsonl")
    }

    // MARK: - Regression guards

    @Test("Path 1 (restored snapshot) wins over path 3")
    func path1WinsOverPath3() {
        let resolver = makeResolver(
            remoteContext: ctx(remoteHome: "/home/ubuntu"),
            remoteSession: "SESSION-REMOTE",
            restoredSnapshots: [
                Self.panelID: RestoredAgentSnapshot(
                    agentKind: .claude,
                    sessionID: "SESSION-RESTORED",
                    workingDirectory: "/Users/local/proj"
                )
            ]
        )
        let resolved = resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID)
        #expect(resolved?.sessionID == "SESSION-RESTORED")
        // Restored snapshot is local — transport defaults to .local.
        #expect(resolved?.transport == .local)
    }

    @Test("Path 2 (live PID + hook) wins over path 3")
    func path2WinsOverPath3() {
        let pid: Int32 = 4242
        let resolver = makeResolver(
            remoteContext: ctx(remoteHome: "/home/ubuntu"),
            remoteSession: "SESSION-REMOTE",
            pidsForPanel: [Self.panelID: [pid]],
            hookRecords: [
                pid: AgentHookSessionMatch(
                    agentKind: .claude,
                    sessionID: "SESSION-FROM-HOOK",
                    cwd: "/Users/local/proj",
                    transcriptPath: "/Users/local/.claude/projects/-Users-local-proj/SESSION-FROM-HOOK.jsonl"
                )
            ]
        )
        let resolved = resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID)
        #expect(resolved?.sessionID == "SESSION-FROM-HOOK")
        #expect(resolved?.transport == .local)
    }

    @Test("Empty remoteHome suppresses path 3 — returns nil")
    func emptyRemoteHomeSuppresses() {
        let resolver = makeResolver(
            remoteContext: ctx(remoteHome: ""),
            remoteSession: "SESSION-REMOTE"
        )
        #expect(resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID) == nil)
    }

    @Test("Missing manual session id suppresses path 3 — returns nil")
    func missingSessionSuppresses() {
        let resolver = makeResolver(
            remoteContext: ctx(remoteHome: "/home/ubuntu"),
            remoteSession: nil
        )
        #expect(resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID) == nil)
    }

    @Test("Missing remote context suppresses path 3 — returns nil")
    func missingContextSuppresses() {
        let resolver = makeResolver(
            remoteContext: nil,
            remoteSession: "SESSION-REMOTE"
        )
        #expect(resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID) == nil)
    }

    @Test("Codex agent kind suppresses path 3 (deferred to §16.L)")
    func codexSuppressed() {
        let codexCtx = RemoteAttachContext(
            sshTransport: Self.testTransport,
            cwd: "/home/ubuntu/proj",
            remoteHome: "/home/ubuntu",
            destination: Self.testTransport.destination,
            agentKind: .codex
        )
        let resolver = AgentSessionResolver(
            agentPIDsForPanel: { _ in [] },
            hookRecordForPID: { _ in nil },
            restoredSnapshotForPanel: { _ in nil },
            remoteContextForPanel: { _ in codexCtx },
            remoteSessionForPanel: { _, _ in "SESSION-REMOTE" }
        )
        #expect(resolver.resolve(panelID: Self.panelID, workspaceID: Self.workspaceID) == nil)
    }
}
