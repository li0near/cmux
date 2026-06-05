import Foundation

/// Snapshot of "what would AgentX-ray need to attach the focused
/// terminal to a remote claude session?" — assembled by the host on
/// demand.
///
/// Carried into ``AgentSessionResolver``'s path-3 fallthrough so the
/// resolver can synthesize a ``ResolvedAgentSession`` with
/// ``SessionTransport/remote(_:)`` whenever the focused terminal is
/// running ssh and the user has previously typed a session id for the
/// `(destination, cwd, agentKind)` triple.
///
/// `remoteHome` is the absolute remote path of `$HOME` for the SSH
/// endpoint. The host pre-resolves it via ``RemoteHomeResolver`` (one
/// `ssh exec echo $HOME` per `(destination, port, identityFile,
/// controlPath)` quadruple, cached). When `remoteHome.isEmpty`, path 3
/// suppresses itself — the resolver will not synthesize a session
/// without a known absolute home, and the panel keeps rendering the
/// remote-attach prompt instead.
///
/// The package never imports cmux-app types; this struct carries every
/// piece of cmux-side state path 3 reads.
public struct RemoteAttachContext: Equatable, Sendable {

    /// SSH transport for the focused terminal. May come from the
    /// workspace-level ``WorkspaceRemoteConfiguration`` *or* from a
    /// per-tab ssh subprocess inferred via cmux's
    /// `TerminalSSHSessionDetector`.
    public let sshTransport: SSHTransport

    /// The terminal panel's working directory on the **remote** host.
    /// Used both as input to the transcript-path encoding (Claude Code
    /// derives transcript filenames from cwd) and as part of the
    /// persistence key so distinct projects on the same host get
    /// distinct stored session ids.
    public let cwd: String

    /// Absolute remote `$HOME`. Empty string means "not yet resolved" —
    /// path 3 will return nil for this panel until the host has
    /// resolved and cached the home for `sshTransport`.
    public let remoteHome: String

    /// SSH destination string (e.g. `ubuntu@10.0.0.1`). Lifted out of
    /// `sshTransport.destination` for direct use as a persistence-key
    /// component.
    public let destination: String

    /// Which agent kind the persisted session id is for. Today only
    /// ``ResolvedAgentSession/AgentKind/claude`` is in scope; codex
    /// remote attach is tracked under MIGRATION_PLAN §16.L.
    public let agentKind: ResolvedAgentSession.AgentKind

    public init(
        sshTransport: SSHTransport,
        cwd: String,
        remoteHome: String,
        destination: String,
        agentKind: ResolvedAgentSession.AgentKind
    ) {
        self.sshTransport = sshTransport
        self.cwd = cwd
        self.remoteHome = remoteHome
        self.destination = destination
        self.agentKind = agentKind
    }
}
