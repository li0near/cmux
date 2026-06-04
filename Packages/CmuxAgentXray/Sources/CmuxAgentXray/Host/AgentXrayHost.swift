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

    // MARK: Panel intent → cmux side actions

    /// Open a detail tab in the same workspace pane as the live panel
    /// identified by `panelID`. Returns the detail panel object the
    /// host created (opaque to the package — used by tests / future
    /// programmatic close).
    @discardableResult
    func openDetailTab(content: DetailContent, fromPanelID panelID: UUID) -> AgentXrayPanel?

    /// Update the host-side display title for `panelID` (tab label,
    /// window subtitle).
    func updateTitle(panelID: UUID, title: String)

    /// Trigger an attention flash on the panel chrome (for
    /// notification-style highlighting).
    func flashAttention(panelID: UUID, reason: AttentionFlashReason)
}
