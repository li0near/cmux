import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    // MARK: - Remote attach (path 3) — derived state + actions

    /// True when the panel should render the remote-attach prompt: no
    /// session attached AND the host reports a remote context for the
    /// currently-tracked terminal (workspace-level SSH OR a per-tab
    /// `ssh` subprocess inferred via `TerminalSSHSessionDetector`).
    ///
    /// Note: this is true even before the host has resolved the remote
    /// `$HOME` — the prompt itself triggers `$HOME` resolution on
    /// submit, so we want the user to see the prompt immediately.
    public var canShowRemoteAttachPrompt: Bool {
        guard case .live = mode else { return false }
        guard resolvedSession == nil else { return false }
        return host.currentTerminalRemoteContext() != nil
    }

    /// SSH destination string to display in the prompt header
    /// (`"Attaching to <destination>"`). Read from the host's current
    /// remote context.
    public var remoteAttachDestination: String? {
        host.currentTerminalRemoteContext()?.destination
    }

    /// Submit a user-supplied claude session id (or nil to clear).
    /// Flips the `remoteAttachInFlight` toggle to `true` and forwards
    /// to the host; the host's async resolve+write+recompute pipeline
    /// drives the result. The `inFlight` flag clears in
    /// `handleSessionChange(_:)` when the new session arrives, or when
    /// the user clicks "Change" (clearing).
    public func setRemoteClaudeSessionID(_ sessionID: String?) {
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Only show the spinner for non-nil submits; clearing is
        // immediate.
        remoteAttachInFlight = (normalized != nil)
        host.attachRemoteClaudeSessionID(normalized)
    }
}
