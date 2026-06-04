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

    private let agentPIDsForPanel: AgentPIDsForPanel
    private let hookRecordForPID: HookRecordForPID

    public init(
        agentPIDsForPanel: @escaping AgentPIDsForPanel,
        hookRecordForPID: @escaping HookRecordForPID
    ) {
        self.agentPIDsForPanel = agentPIDsForPanel
        self.hookRecordForPID = hookRecordForPID
    }

    @MainActor
    public func resolve(
        panelID: UUID,
        workspaceID: String
    ) -> ResolvedAgentSession? {
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
        return nil
    }
}
