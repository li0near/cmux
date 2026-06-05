public import Foundation
internal import CryptoKit

/// User-supplied claude session ids for SSH-backed terminals, persisted
/// in `UserDefaults`. Read by ``AgentSessionResolver``'s path 3 and
/// written by the panel's `setRemoteClaudeSessionID(_:)` action when the
/// user submits the inline remote-attach prompt.
///
/// Persistence key shape: `agentXray.remote.session.<sha256-hex-of-
/// destination|cwd|kind>`. The triple keys the entry to a specific
/// project on a specific host so:
/// - Workspace renames don't strand the id (key is independent of
///   `Workspace.title` / `Workspace.id`).
/// - Two projects on the same host get distinct ids.
/// - The same project SSH'd into from different hosts gets distinct ids.
///
/// Pure value type — inject `UserDefaults(suiteName:)` for test isolation.
public struct RemoteSessionStore: Sendable {

    // UserDefaults is Apple-documented thread-safe; the
    // `nonisolated(unsafe)` annotation is the carve-out CLAUDE.md
    // sanctions for this exact case.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read the persisted session id for the given `(destination, cwd,
    /// agentKind)` triple. Returns nil when nothing is stored or the
    /// stored value is the empty string.
    public func read(
        destination: String,
        cwd: String,
        agentKind: ResolvedAgentSession.AgentKind
    ) -> String? {
        let raw = defaults.string(
            forKey: Self.key(destination: destination, cwd: cwd, agentKind: agentKind)
        )
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Persist a session id, or pass `nil` to clear the entry. Whitespace
    /// is trimmed; empty input clears (treated identically to nil).
    public func write(
        destination: String,
        cwd: String,
        agentKind: ResolvedAgentSession.AgentKind,
        sessionID: String?
    ) {
        let key = Self.key(destination: destination, cwd: cwd, agentKind: agentKind)
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Stable key shape. Public so tests can assert key changes when
    /// any input differs and stay equal otherwise.
    public static func key(
        destination: String,
        cwd: String,
        agentKind: ResolvedAgentSession.AgentKind
    ) -> String {
        let composite = "\(destination)|\(cwd)|\(agentKind.rawValue)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "agentXray.remote.session.\(hex)"
    }
}
