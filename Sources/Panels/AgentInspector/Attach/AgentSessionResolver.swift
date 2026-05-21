import Foundation

/// A resolved Claude/Codex session linked to a specific terminal surface in cmux.
public struct ResolvedAgentSession: Equatable, Sendable {
    public let agentKind: AgentKind
    public let sessionId: String
    public let workspaceId: String
    public let surfaceId: String
    public let cwd: String?
    public let transcriptPath: String?

    public enum AgentKind: String, Equatable, Sendable {
        case claude
        case codex
    }

    public init(
        agentKind: AgentKind,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?
    ) {
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

/// Resolves a `(workspaceId, surfaceId)` pair to a live `ResolvedAgentSession`.
///
/// Resolution layers, in order:
///
///   1. **Hook stores** — `~/.cmuxterm/{claude,codex}-hook-sessions.json`,
///      written by `cmux claude-hook session-start` and the codex
///      equivalent. Authoritative when populated.
///   2. **Argv scanner** — for restored claude sessions, cmux injects
///      `claude --resume <sessionId>` as the panel's `initialInput`
///      (`Workspace.swift:8063`). Claude's SessionStart hook does NOT
///      reliably fire on `--resume`, so the hook store may be missing
///      records for restored sessions. We read the resume id back from
///      argv via libproc (`ClaudeProcessArgvScanner`) and locate the
///      transcript jsonl by session id.
///
/// We deliberately do NOT use a disk-mtime fallback. Picking the freshest
/// `.jsonl` in `~/.claude/projects/<encoded-cwd>/` cannot disambiguate
/// sibling terminals sharing a cwd — it collapses N sessions into 1.
public struct AgentSessionResolver {
    private let claudeStore: ClaudeHookSessionStore
    private let codexStore: CodexHookSessionStore
    private let fileManager: FileManager
    private let claudeProjectsRoot: String

    public init(
        claudeStore: ClaudeHookSessionStore = ClaudeHookSessionStore(),
        codexStore: CodexHookSessionStore = CodexHookSessionStore(),
        fileManager: FileManager = .default,
        claudeProjectsRoot: String = AgentSessionResolver.defaultClaudeProjectsRoot
    ) {
        self.claudeStore = claudeStore
        self.codexStore = codexStore
        self.fileManager = fileManager
        self.claudeProjectsRoot = claudeProjectsRoot
    }

    public static var defaultClaudeProjectsRoot: String {
        NSString(string: "~/.claude/projects").expandingTildeInPath
    }

    public func resolve(
        workspaceId: String,
        surfaceId: String,
        cwdHint: String? = nil
    ) -> ResolvedAgentSession? {
        let claude = claudeStore.record(forWorkspaceId: workspaceId, surfaceId: surfaceId)
        let codex = codexStore.record(forWorkspaceId: workspaceId, surfaceId: surfaceId)

        switch (claude, codex) {
        case (.some(let c), .some(let x)):
            if x.updatedAt > c.updatedAt {
                return .init(
                    agentKind: .codex,
                    sessionId: x.sessionId,
                    workspaceId: x.workspaceId,
                    surfaceId: x.surfaceId,
                    cwd: x.cwd,
                    transcriptPath: x.transcriptPath
                )
            }
            return .init(
                agentKind: .claude,
                sessionId: c.sessionId,
                workspaceId: c.workspaceId,
                surfaceId: c.surfaceId,
                cwd: c.cwd,
                transcriptPath: c.transcriptPath
            )
        case (.some(let c), .none):
            return .init(
                agentKind: .claude,
                sessionId: c.sessionId,
                workspaceId: c.workspaceId,
                surfaceId: c.surfaceId,
                cwd: c.cwd,
                transcriptPath: c.transcriptPath
            )
        case (.none, .some(let x)):
            return .init(
                agentKind: .codex,
                sessionId: x.sessionId,
                workspaceId: x.workspaceId,
                surfaceId: x.surfaceId,
                cwd: x.cwd,
                transcriptPath: x.transcriptPath
            )
        case (.none, .none):
            return nil
        }
    }
}
