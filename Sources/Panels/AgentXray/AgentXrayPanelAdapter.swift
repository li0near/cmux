import AppKit
import CmuxAgentXray
import Combine
import Foundation

/// App-target `Panel`-protocol wrapper around a package-side
/// `CmuxAgentXray.AgentXrayPanel`.
///
/// Why a wrapper exists: cmux's `Panel` protocol requires
/// `ObservableObject` conformance (Combine). The package's
/// `AgentXrayPanel` deliberately uses `@Observable` (the Observation
/// framework, not Combine). The two patterns don't cross-conform, so
/// this adapter holds a strong reference to the package panel and
/// forwards every `Panel`-protocol method onto it. Title changes are
/// bridged via a Task-loop on `withObservationTracking` that bumps a
/// `@Published` tick so cmux's tab bar redraws.
///
/// Lifetime: `Workspace` owns the adapter via its `panels` dictionary;
/// the adapter borrows the workspace-scoped `AgentXrayWorkspaceHost`
/// (lazy-init on first AgentX-ray panel in the workspace). On `init`,
/// the adapter registers itself with the host's per-panel registry; on
/// `close()`, it deregisters.
@MainActor
@available(macOS 15, *)
final class AgentXrayPanelAdapter: Panel, ObservableObject {

    // MARK: - Panel protocol

    let id: UUID
    let panelType: PanelType = .agentXray

    var displayTitle: String { xrayPanel.displayTitle }
    var displayIcon: String? { xrayPanel.displayIconSymbol }
    var isDirty: Bool { false }

    // MARK: - Owned state

    /// Package-side ViewModel.
    let xrayPanel: AgentXrayPanel

    /// Workspace that hosts this panel. Held weakly to avoid the
    /// retain cycle: Workspace owns the panels collection, and the
    /// panel's host pointer must not extend Workspace's lifetime.
    private(set) weak var workspace: Workspace?

    /// Mirror of the Combine ObservableObject change publisher.
    /// Bumped when `xrayPanel.displayTitle` changes so the cmux tab
    /// bar re-renders.
    @Published private(set) var titleTick: Int = 0

    private var titleObservationTask: Task<Void, Never>?

    /// Workspace-scoped host that this panel adapter borrows. Strong
    /// reference because Workspace holds the host weakly through its
    /// own storage; the adapter keeps it alive for the panel's
    /// lifetime.
    private let workspaceHost: AgentXrayWorkspaceHost

    // MARK: - Init / deinit

    init(workspace: Workspace) {
        self.workspace = workspace
        let host = workspace.agentXrayWorkspaceHostLazy()
        self.workspaceHost = host
        let panel = AgentXrayPanel(host: host)
        self.xrayPanel = panel
        self.id = panel.id
        host.register(panel: self)
        startTitleObservation()
    }

    init(workspace: Workspace, detail: DetailContent) {
        self.workspace = workspace
        let host = workspace.agentXrayWorkspaceHostLazy()
        self.workspaceHost = host
        let panel = AgentXrayPanel(host: host, detail: detail)
        self.xrayPanel = panel
        self.id = panel.id
        host.register(panel: self)
        // Detail panels don't change title — no observation needed.
    }

    deinit {
        titleObservationTask?.cancel()
    }

    // MARK: - Title observation

    private func startTitleObservation() {
        titleObservationTask?.cancel()
        titleObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self != nil {
                await Self.awaitNextTitleChange { [weak self] in
                    _ = self?.xrayPanel.displayTitle
                }
                guard let self else { return }
                self.titleTick &+= 1
            }
        }
    }

    private static func awaitNextTitleChange(
        _ access: @escaping @MainActor () -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                access()
            } onChange: {
                continuation.resume()
            }
        }
    }

    // MARK: - Panel protocol methods

    func close() {
        titleObservationTask?.cancel()
        titleObservationTask = nil
        workspaceHost.deregister(panelID: id)
        xrayPanel.close()
    }

    func focus() {
        xrayPanel.focus()
    }

    func unfocus() {
        xrayPanel.unfocus()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        // Map cmux flash-reason taxonomy to the package reason.
        let mapped: AttentionFlashReason
        switch reason {
        case .navigation:
            mapped = .focus
        case .notificationArrival, .notificationDismiss:
            mapped = .activity
        case .unreadIndicatorDismiss, .debug:
            mapped = .other
        }
        xrayPanel.triggerFlash(reason: mapped)
    }
}

// MARK: - Package panel side bridges

@available(macOS 15, *)
extension AgentXrayPanel {
    /// No internal focus state to claim — the row list owns its own
    /// selection state via SwiftUI focus.
    func focus() {}
    func unfocus() {}
}
