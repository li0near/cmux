import AppKit
import CmuxAgentXray
import Combine
import Foundation

/// Per-panel `AgentXrayHost` adapter. Bridges the package's host
/// protocol onto cmux's AppKit / NotificationCenter / Workspace
/// surfaces.
///
/// One `AgentXrayWorkspaceHost` instance is created per
/// `AgentXrayPanelHost` (one per live panel). It owns:
///   - a `WorkspaceFocusObserver` that publishes `ResolvedAgentSession`
///     updates as the focused terminal changes,
///   - notification observer tokens for `.ghosttyDidUpdateScrollbar`
///     and `.cmuxClaudePromptSubmitted`,
///   - any handler-cancellation `Cancellable` instances handed to the
///     package panel during its `wireHostSubscriptions()` step.
@MainActor
@available(macOS 15, *)
final class AgentXrayWorkspaceHost: AgentXrayHost {

    // MARK: - AgentXrayHost / identity

    var workspaceID: UUID { workspaceUUID }

    private let workspaceUUID: UUID
    private weak var workspace: Workspace?
    private weak var panelHost: AgentXrayPanelHost?

    // MARK: - Owned subsystems

    private let focusObserver: WorkspaceFocusObserver
    private var focusCancellables: [WeakCancellableBox] = []

    init(workspace: Workspace, panelHost: AgentXrayPanelHost? = nil) {
        self.workspaceUUID = workspace.id
        self.workspace = workspace
        self.panelHost = panelHost
        self.focusObserver = WorkspaceFocusObserver(workspace: workspace)
    }

    /// Called by `AgentXrayPanelHost.init` after the host instance is
    /// fully wired up so the host can hold a weak reference to its
    /// owning panel.
    func bind(panelHost: AgentXrayPanelHost) {
        self.panelHost = panelHost
    }

    // MARK: - Focus tracking

    func currentFocusedSession() -> ResolvedAgentSession? {
        focusObserver.current
    }

    func observeFocusChanges(
        _ handler: @escaping @MainActor () -> Void
    ) -> any AgentXrayCancellable {
        let combineCancellable = focusObserver.$current
            .dropFirst() // initial value already delivered synchronously
            .sink { _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
        let token = HostCancellable(combine: combineCancellable)
        return token
    }

    // MARK: - Scrollbar state

    func scrollbarSnapshot(forSurfaceID id: UUID) -> ScrollbarSnapshot? {
        WorkspaceScrollbarBridge.shared.latest(for: id)
    }

    func observeScrollbarChanges(
        _ handler: @escaping @MainActor (UUID) -> Void
    ) -> any AgentXrayCancellable {
        let token = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let view = note.object as? GhosttyNSView,
                      let surfaceID = view.terminalSurface?.id else { return }
                handler(surfaceID)
            }
        }
        return HostCancellable(notificationToken: token)
    }

    // MARK: - Claude anchor payloads

    func observeClaudeAnchorPayloads(
        _ handler: @escaping @MainActor (ClaudeAnchorPayload) -> Void
    ) -> any AgentXrayCancellable {
        let token = NotificationCenter.default.addObserver(
            forName: .cmuxClaudePromptSubmitted,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let payload = note.claudeAnchorPayload else { return }
                handler(payload)
            }
        }
        return HostCancellable(notificationToken: token)
    }

    // MARK: - Panel intent → cmux side actions

    @discardableResult
    func openDetailTab(content: DetailContent, fromPanelID panelID: UUID) -> AgentXrayPanel? {
        guard let workspace, let panelHost else { return nil }
        return workspace.openAgentXrayDetail(
            content: content,
            fromPanelID: panelID,
            originPanelHost: panelHost
        )?.xrayPanel
    }

    func updateTitle(panelID: UUID, title: String) {
        _ = workspace?.updatePanelTitle(panelId: panelID, title: title)
    }

    func flashAttention(panelID: UUID, reason: AttentionFlashReason) {
        _ = reason
        // Translate to cmux taxonomy and route through the workspace.
        // Mapped uniformly to .navigation since the package's reasons
        // (focus / activity / attach / other) all map to navigation-
        // style flashes from cmux's perspective.
        workspace?.requestFlash(panelId: panelID, reason: .navigation)
    }
}

// MARK: - Cancellable helpers

/// Concrete `CmuxAgentXray.Cancellable` for the host-protocol's
/// observation methods. Wraps either an `AnyCancellable` (for Combine
/// publishers) or a `NotificationCenter` observer token. `cancel()`
/// is idempotent.
@MainActor
@available(macOS 15, *)
final class HostCancellable: AgentXrayCancellable {
    private var combine: AnyCancellable?
    private var notificationToken: NSObjectProtocol?

    init(combine: AnyCancellable) {
        self.combine = combine
    }

    init(notificationToken: NSObjectProtocol) {
        self.notificationToken = notificationToken
    }

    func cancel() {
        combine?.cancel()
        combine = nil
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
        notificationToken = nil
    }

    deinit {
        // Cancellation is allowed from any actor; the underlying
        // operations (AnyCancellable.cancel, removeObserver) are
        // thread-safe.
        combine?.cancel()
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
    }
}

/// Wraps a Cancellable so it can be referenced weakly without keeping
/// the upstream subscription alive — currently unused but retained for
/// future host-shutdown paths.
@available(macOS 15, *)
private struct WeakCancellableBox {
    weak var cancellable: HostCancellable?
}

// MARK: - Workspace flash request bridging

@available(macOS 15, *)
extension Workspace {
    /// Bumps the workspace's flash pipeline for the given panel.
    /// Lightweight extension shim so AgentXrayWorkspaceHost can route
    /// AttentionFlashReason → WorkspaceAttentionFlashReason without
    /// reaching directly into Workspace internals.
    fileprivate func requestFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        guard let panel = panels[panelId] else { return }
        panel.triggerFlash(reason: reason)
    }
}
