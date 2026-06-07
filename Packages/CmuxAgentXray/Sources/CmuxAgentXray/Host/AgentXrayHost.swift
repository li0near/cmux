public import Foundation

/// The protocol the cmux app conforms to in order to embed
/// `AgentXrayPanel`. Strict isolation contract: the package never
/// references cmux-app types (`Workspace`, `TerminalPanel`, `Bonsplit`,
/// `GhosttyNSView`, etc.). Everything the panel needs to read or
/// influence on the cmux side passes through this protocol.
///
/// All methods are `@MainActor`-isolated. The panel is `@MainActor`
/// itself; the host implementations route AppKit / NotificationCenter
/// callbacks onto the main actor before invoking the supplied handlers.
@MainActor
@available(macOS 15, *)
public protocol AgentXrayHost: AnyObject {
    // MARK: Identity

    /// Stable workspace identifier — used by `TurnAnchorStore` to
    /// scope anchors to (workspace, surface) pairs.
    var workspaceID: UUID { get }

    /// Logger seam. The host implements this to route package log
    /// events to its own observability stack (e.g. `os.Logger` +
    /// `cmuxDebugLog`). Tests can pass `NoOpAgentXrayLogger`.
    var logger: any AgentXrayLogger { get }

    // MARK: Focus tracking

    /// The agent session currently in focus (if any). Read at attach
    /// time and whenever the panel needs the latest synchronously.
    func currentFocusedSession() -> ResolvedAgentSession?

    /// Subscribe to focus changes. The handler is called on the main
    /// actor whenever the focused session changes (including to `nil`).
    /// Cancel via the returned token.
    func observeFocusChanges(
        _ handler: @escaping @MainActor () -> Void
    ) -> any AgentXrayCancellable

    // MARK: Scrollbar state (drives snap-mode visible-turn filter)

    /// Latest scrollbar snapshot for the given terminal surface, if
    /// the host has one cached. nil before the first scrollbar event.
    func scrollbarSnapshot(forSurfaceID id: UUID) -> ScrollbarSnapshot?

    /// Subscribe to scrollbar updates. The surface id of the changed
    /// terminal is passed in. Coalescing / throttling is the host's
    /// responsibility.
    func observeScrollbarChanges(
        _ handler: @escaping @MainActor (UUID) -> Void
    ) -> any AgentXrayCancellable

    // MARK: Live anchor pipeline (cmux fires; package consumes)

    /// Subscribe to `claude_anchor` payloads delivered by the cmux app's
    /// CLI socket handler. The handler is invoked on the main actor.
    func observeClaudeAnchorPayloads(
        _ handler: @escaping @MainActor (ClaudeAnchorPayload) -> Void
    ) -> any AgentXrayCancellable

    // MARK: Live agent registry (cmux's source-of-truth for "what
    // agents are running in what panels"). Used by `AgentSessionResolver`
    // to attach without process inspection.

    /// Live agent PIDs (claude/codex) registered for the given panel.
    /// Backed by cmux's `set_agent_pid` registry; populated when the
    /// cmux CLI's hook handler fires. Empty if no agent has registered
    /// for that panel yet.
    func agentPIDs(forPanelID panelID: UUID) -> [Int32]

    /// Look up the cmux CLI's SessionStart hook record whose `pid`
    /// field matches `pid`. Walks both the claude and codex stores.
    /// Returns nil if no record matches (e.g. the agent hasn't fired
    /// its SessionStart hook yet). The `agentKind` field discriminates
    /// which store the record came from.
    func findAgentHookRecord(byPID pid: Int32) -> AgentHookSessionMatch?

    /// Look up cmux's `restoredAgentSnapshotsByPanelId[panelId]` for
    /// auto-resumed panels. Pre-mapped onto the fresh panel UUID at
    /// restoration time. Returns nil for panels that weren't restored
    /// (e.g. fresh panels created post-boot) or whose restored agent
    /// kind isn't `.claude` / `.codex`.
    func restoredAgentSnapshot(forPanelID panelID: UUID) -> RestoredAgentSnapshot?

    // MARK: Panel intent → cmux side actions

    /// Open a detail tab in the same workspace pane as the live panel
    /// identified by `panelID`. Returns the detail panel object the
    /// host created (opaque to the package — used by tests / future
    /// programmatic close).
    ///
    /// `activate: true` (default) focuses the new panel after open;
    /// `activate: false` opens it in the background. AgentX-ray's
    /// click handler maps Cmd-click → `activate: false` so users can
    /// queue up multiple detail tabs without losing AgentX-ray
    /// context.
    @discardableResult
    func openDetailTab(content: DetailContent, fromPanelID panelID: UUID, activate: Bool) -> AgentXrayPanel?

    /// Update the host-side display title for `panelID` (tab label,
    /// window subtitle).
    func updateTitle(panelID: UUID, title: String)

    /// Trigger an attention flash on the panel chrome (for
    /// notification-style highlighting).
    func flashAttention(panelID: UUID, reason: AttentionFlashReason)

    // MARK: Open file in cmux panel (URL-click flow reuse)

    /// Open a file URL as a real cmux panel — `MarkdownPanel` for
    /// markdown-shaped paths, `FilePreviewPanel` for everything else.
    /// Mirrors the flow that fires when a user clicks an inline file
    /// path in the terminal. The host opens the file via cmux's
    /// existing extension-dispatch pipeline; AgentX-ray uses this
    /// instead of embedding renderers in-package so users get cmux's
    /// full panel chrome (font controls, copy as markdown / HTML,
    /// edit toggle, "Open in…", image zoom, find-in-content) for free.
    ///
    /// - Parameters:
    ///   - fileURL: Absolute file URL. The file should exist on disk
    ///     by the time this is called (caller materializes inline
    ///     content first; offloaded outputs already live on disk).
    ///   - activate: Whether to steal window focus. Default false —
    ///     AgentX-ray panels often run in background workspaces.
    ///   - reuseExisting: When true, refocus an existing panel that
    ///     already points at the same canonical path instead of
    ///     duplicating. Combined with stable per-`(sourceEntryID,
    ///     sectionIndex)` filenames, re-clicks of the same row
    ///     dedupe.
    /// - Returns: UUID of the opened (or refocused) panel, nil on
    ///   failure (no workspace, no available pane, etc.).
    ///
    /// Default: returns nil so test stubs and out-of-tree hosts
    /// compile unchanged.
    @discardableResult
    func openFileInPanel(
        _ fileURL: URL,
        activate: Bool,
        reuseExisting: Bool
    ) -> UUID?

    /// Convenience for image-shaped Section content. Decodes the
    /// base64 bytes off-main, writes them to a stable temp path keyed
    /// by `(sourceEntryID, sectionIndex)`, then opens the resulting
    /// file via ``openFileInPanel(_:activate:reuseExisting:)``. Means
    /// the package never has to thread `ImageSource` through
    /// `DetailContent` — image clicks short-circuit at the
    /// click-handler level and call this directly.
    ///
    /// `activate: true` (default) focuses the new panel; Cmd-click
    /// flips it to `false` so the panel opens in the background.
    ///
    /// Default: no-op.
    func openImageInPanel(
        source: ImageSource,
        sourceEntryID: String,
        sectionIndex: Int,
        activate: Bool
    )

    // MARK: Remote attach (path 3)

    /// Snapshot of "what would AgentX-ray need to attach the focused
    /// terminal to a remote claude session?". Returns nil for fully-
    /// local terminals (no SSH transport in scope). Read atomically off
    /// the host so the panel's path-3 fast path stays consistent.
    ///
    /// The host populates the cached remote `$HOME` when known via
    /// ``RemoteAttachContext/remoteHome``. An empty `remoteHome`
    /// signals "I know this terminal is remote, but I haven't resolved
    /// its `$HOME` yet" — the panel still surfaces the remote-attach
    /// prompt; submitting it triggers `$HOME` resolution.
    func currentTerminalRemoteContext() -> RemoteAttachContext?

    /// Persist a user-supplied claude session id for the currently-
    /// tracked terminal's remote endpoint and trigger a focus
    /// recompute. Pass `nil` to clear the persisted id (the panel
    /// detaches and re-renders the prompt).
    ///
    /// The host owns the persistence (`UserDefaults`) instance and the
    /// `$HOME` resolver; this method may run async work behind the
    /// scenes (e.g. resolving `$HOME` on first attach) before the next
    /// recompute fires.
    func attachRemoteClaudeSessionID(_ sessionID: String?)
}

// MARK: - Default no-op detail renderers

/// Default implementations for the open-in-panel seams. Out-of-tree
/// hosts and test stubs inherit these no-ops so they don't have to
/// implement the cmux-specific panel pipeline. cmux's
/// `AgentXrayWorkspaceHost` overrides both.
@available(macOS 15, *)
extension AgentXrayHost {
    public func openFileInPanel(
        _ fileURL: URL,
        activate: Bool,
        reuseExisting: Bool
    ) -> UUID? {
        nil
    }

    public func openImageInPanel(
        source: ImageSource,
        sourceEntryID: String,
        sectionIndex: Int,
        activate: Bool
    ) {
        // No-op default. cmux's host conformance overrides.
    }
}
