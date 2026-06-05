public import Foundation

/// A resolved Claude/Codex session linked to a specific terminal
/// surface in cmux.
public struct ResolvedAgentSession: Equatable, Sendable {
    public let agentKind: AgentKind
    public let sessionID: String
    public let workspaceID: String
    public let surfaceID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let transport: SessionTransport

    public enum AgentKind: String, Equatable, Sendable {
        case claude
        case codex
    }

    public init(
        agentKind: AgentKind,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        cwd: String?,
        transcriptPath: String?,
        transport: SessionTransport = .local
    ) {
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.transport = transport
    }
}

/// Where a `ResolvedAgentSession`'s transcript bytes live and how to
/// stream them.
public enum SessionTransport: Equatable, Sendable {
    /// Transcript file is on the local filesystem; stream via
    /// `JSONLTail` (DispatchSource vnode watch).
    case local

    /// Transcript file is on a remote SSH host; stream via
    /// `RemoteJSONLStream` (`ssh exec tail -F` over the existing
    /// SSH ControlMaster socket).
    case remote(SSHTransport)
}

/// Subset of cmux's `WorkspaceRemoteConfiguration` that the package
/// needs to spawn an `ssh` subprocess. Carried in
/// `SessionTransport.remote(_:)` so the package never imports cmux
/// types.
public struct SSHTransport: Equatable, Sendable {
    public let destination: String
    public let port: Int?
    public let identityFile: String?
    /// Path to the SSH ControlMaster socket (e.g.
    /// `/tmp/cmux-ssh-501-12345-%C`). Reused so the remote tail
    /// doesn't pay another auth round-trip.
    public let controlPath: String?

    public init(
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        controlPath: String? = nil
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.controlPath = controlPath
    }
}

/// One match against the cmux CLI's `~/.cmuxterm/{claude,codex}-hook-
/// sessions.json` files, looked up by PID. Carries the
/// `ResolvedAgentSession`-relevant fields plus the `agentKind`
/// discriminator (which JSON file the record came from).
public struct AgentHookSessionMatch: Equatable, Sendable {
    public let agentKind: ResolvedAgentSession.AgentKind
    public let sessionID: String
    public let cwd: String?
    public let transcriptPath: String?

    public init(
        agentKind: ResolvedAgentSession.AgentKind,
        sessionID: String,
        cwd: String?,
        transcriptPath: String?
    ) {
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

/// Mirror of cmux's `restoredAgentSnapshotsByPanelId[panelId]` for one
/// panel — the kind / sessionID / cwd of an auto-resumed agent that's
/// being respawned by cmux's restoration flow but may not have a live
/// PID yet. Lets the resolver synthesize a `ResolvedAgentSession`
/// before the agent process exists.
public struct RestoredAgentSnapshot: Equatable, Sendable {
    public let agentKind: ResolvedAgentSession.AgentKind
    public let sessionID: String
    public let workingDirectory: String

    public init(
        agentKind: ResolvedAgentSession.AgentKind,
        sessionID: String,
        workingDirectory: String
    ) {
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
    }
}

/// Resolves a panel's `ResolvedAgentSession` by joining two pieces of
/// state cmux already maintains as authoritative source-of-truth:
///
///   1. `host.agentPIDs(forPanelID:)` — cmux's panel-scoped registry
///      of live agent PIDs. Populated by the cmux CLI's
///      `set_agent_pid` call when an agent process starts; cleaned
///      up by lifecycle events.
///   2. `host.findAgentHookRecord(byPID:)` — lookup against
///      `~/.cmuxterm/{claude,codex}-hook-sessions.json`, written by
///      the cmux CLI's SessionStart hook. Carries `(sessionID, cwd,
///      transcriptPath)`.
///
/// Both signals are stable across cmux restart (PIDs are valid for
/// the lifetime of the running process; the hook store file persists
/// on disk). Joining them by PID avoids the `(workspaceId, surfaceId)`
/// staleness problem the previous resolver had — workspaceId is
/// freshly minted on every cmux launch but PID is not.
///
/// Same flow handles every case:
///   - **Tab switch / first open** — agent already running, both
///     signals present, resolves immediately.
///   - **Post-restart auto-resume** — claude spawned by the resume
///     script; cmux's `set_agent_pid` registers, hook fires, record
///     materializes; resolver picks it up on the next focus event.
///   - **Bare `claude`** — same flow as auto-resume; argv doesn't
///     matter because we don't read argv.
///   - **`/new` mid-session** — same PID, hook re-fires upserting the
///     record with the new sessionID; next resolve finds the new id.
///
/// Failure modes:
///   - PID registered but hook hasn't fired yet — brief "Detached"
///     window, sub-second. Resolves on the next focus event.
///   - Hook handler is misconfigured / not running — panel stays
///     detached. We don't paper over this; the cmux hook system is
///     the canonical signal.
public struct AgentSessionResolver: Sendable {
    public typealias AgentPIDsForPanel = @MainActor (UUID) -> [Int32]
    public typealias HookRecordForPID = @MainActor (Int32) -> AgentHookSessionMatch?
    public typealias RestoredSnapshotForPanel = @MainActor (UUID) -> RestoredAgentSnapshot?
    /// Path-3 input: returns a `RemoteAttachContext` for the panel when
    /// the focused terminal is on an SSH transport (workspace-level
    /// remote OR per-tab inferred ssh subprocess), or nil for fully-
    /// local panels. The host populates the cached `remoteHome`; an
    /// empty `remoteHome` suppresses the path-3 synthesis but lets the
    /// panel still render the remote-attach prompt.
    public typealias RemoteContextForPanel = @MainActor (UUID) -> RemoteAttachContext?
    /// Path-3 input: returns the user-supplied claude session id for
    /// the given panel + remote context, or nil if the user has not
    /// yet typed one for this `(destination, cwd, agentKind)` triple.
    public typealias RemoteSessionForPanel = @MainActor (UUID, RemoteAttachContext) -> String?

    private let agentPIDsForPanel: AgentPIDsForPanel
    private let hookRecordForPID: HookRecordForPID
    private let restoredSnapshotForPanel: RestoredSnapshotForPanel
    private let remoteContextForPanel: RemoteContextForPanel
    private let remoteSessionForPanel: RemoteSessionForPanel
    private let claudeProjectsRoot: String

    public init(
        agentPIDsForPanel: @escaping AgentPIDsForPanel,
        hookRecordForPID: @escaping HookRecordForPID,
        restoredSnapshotForPanel: @escaping RestoredSnapshotForPanel,
        remoteContextForPanel: @escaping RemoteContextForPanel = { _ in nil },
        remoteSessionForPanel: @escaping RemoteSessionForPanel = { _, _ in nil },
        claudeProjectsRoot: String = AgentSessionResolver.defaultClaudeProjectsRoot
    ) {
        self.agentPIDsForPanel = agentPIDsForPanel
        self.hookRecordForPID = hookRecordForPID
        self.restoredSnapshotForPanel = restoredSnapshotForPanel
        self.remoteContextForPanel = remoteContextForPanel
        self.remoteSessionForPanel = remoteSessionForPanel
        self.claudeProjectsRoot = claudeProjectsRoot
    }

    public static var defaultClaudeProjectsRoot: String {
        NSString(string: "~/.claude/projects").expandingTildeInPath
    }

    @MainActor
    public func resolve(
        panelID: UUID,
        workspaceID: String
    ) -> ResolvedAgentSession? {
        // Path 1: restored-snapshot synthesis. Handles the auto-resume
        // case where cmux's restoration has scheduled an agent for the
        // panel but the agent process may not have spawned yet (or has
        // spawned but its SessionStart hook hasn't fired). cmux pre-
        // maps the restored data onto the fresh panel UUID at restore
        // time, so this is panel-bound and not ambiguous.
        //
        // The synthesized `transcriptPath` may not exist on disk yet;
        // `JSONLTail` handles missing files via exponential-backoff
        // open retries and starts streaming as soon as the agent
        // creates the file.
        if let snap = restoredSnapshotForPanel(panelID) {
            let path = transcriptPath(
                forKind: snap.agentKind,
                sessionID: snap.sessionID,
                cwd: snap.workingDirectory
            )
            return ResolvedAgentSession(
                agentKind: snap.agentKind,
                sessionID: snap.sessionID,
                workspaceID: workspaceID,
                surfaceID: panelID.uuidString,
                cwd: snap.workingDirectory,
                transcriptPath: path
            )
        }

        // Path 2: live PID + hook record. Handles fresh panels (user
        // started claude after cmux was running) and `/new` mid-session
        // (snapshot is stale; live hook record reflects the new id).
        for pid in agentPIDsForPanel(panelID) {
            guard let match = hookRecordForPID(pid) else { continue }
            return ResolvedAgentSession(
                agentKind: match.agentKind,
                sessionID: match.sessionID,
                workspaceID: workspaceID,
                surfaceID: panelID.uuidString,
                cwd: match.cwd,
                transcriptPath: match.transcriptPath
            )
        }

        // Path 3: remote attach. Fires only when the host reports a
        // remote context (workspace-level SSH workspace OR per-tab `ssh`
        // subprocess inferred via TerminalSSHSessionDetector) AND the
        // user has typed a session id for this (destination, cwd,
        // agentKind) triple AND the host has resolved + cached the
        // remote `$HOME` so we can build an absolute transcript path.
        // Synthesized session carries `.remote(SSHTransport)` so
        // TranscriptStream dispatches to RemoteJSONLStream.
        if let ctx = remoteContextForPanel(panelID),
           !ctx.remoteHome.isEmpty,
           ctx.agentKind == .claude,
           let remoteID = remoteSessionForPanel(panelID, ctx),
           let path = Self.remoteTranscriptPath(
               forKind: ctx.agentKind,
               sessionID: remoteID,
               cwd: ctx.cwd,
               remoteHome: ctx.remoteHome
           )
        {
            return ResolvedAgentSession(
                agentKind: ctx.agentKind,
                sessionID: remoteID,
                workspaceID: workspaceID,
                surfaceID: panelID.uuidString,
                cwd: ctx.cwd,
                transcriptPath: path,
                transport: .remote(ctx.sshTransport)
            )
        }
        return nil
    }

    /// Path-3 transcript-path builder. Returns an **absolute** remote
    /// path so `RemoteJSONLStream` can pass it through its existing
    /// single-quoting (no tilde expansion needed on the remote shell).
    /// Codex returns nil — codex remote attach is tracked under
    /// MIGRATION_PLAN §16.L (date-bucketed `~/.codex/sessions/<y>/<m>/
    /// <d>/<sid>.jsonl` layout requires walking the directory tree
    /// remotely).
    static func remoteTranscriptPath(
        forKind kind: ResolvedAgentSession.AgentKind,
        sessionID: String,
        cwd: String,
        remoteHome: String
    ) -> String? {
        switch kind {
        case .claude:
            // Claude Code derives transcript filenames from cwd by
            // replacing `/` with `-`; matches the local algorithm
            // applied to `cwd` exactly so the on-remote-disk file
            // tail-targets correctly.
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            // Use string concatenation rather than URL plumbing so we
            // can guarantee the trailing path stays in POSIX form even
            // if `remoteHome` contains odd characters.
            let trimmedHome = remoteHome.hasSuffix("/")
                ? String(remoteHome.dropLast())
                : remoteHome
            return "\(trimmedHome)/.claude/projects/\(encoded)/\(sessionID).jsonl"
        case .codex:
            return nil
        }
    }

    private func transcriptPath(
        forKind kind: ResolvedAgentSession.AgentKind,
        sessionID: String,
        cwd: String
    ) -> String? {
        switch kind {
        case .claude:
            let encoded = (cwd as NSString)
                .standardizingPath
                .replacingOccurrences(of: "/", with: "-")
            return URL(fileURLWithPath: claudeProjectsRoot, isDirectory: true)
                .appendingPathComponent(encoded, isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
                .path
        case .codex:
            // Codex sessions live in date-bucketed
            // `~/.codex/sessions/<year>/<month>/<day>/<sid>.jsonl`
            // dirs; cmux's restored snapshot doesn't carry the
            // bucket. Path 2 (hook record) carries the path
            // explicitly when available; for snapshot-only
            // resolution we leave it nil and let `JSONLTail` no-op.
            return nil
        }
    }
}
