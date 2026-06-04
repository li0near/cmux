import AppKit
import Combine
import CmuxAgentXray
import Foundation

/// Watches a workspace for changes to its focused terminal surface and
/// emits the resolved Claude/Codex session whenever the focused
/// terminal changes.
///
/// Three notification names drive `recompute()`:
///   - `.ghosttyDidFocusSurface` — keyboard focus on a surface
///   - `.ghosttyDidFocusTab` — bonsplit selectedTab change (catches
///     first-click-on-tab without a keyboard focus shift)
///   - `.ghosttyDidBecomeFirstResponderSurface` — pane-level focus
///
/// The store-watcher (Claude hook-session JSON file) catches sessionId
/// changes that don't shift focus (e.g. /clear creates a new session
/// entry).
///
/// Currently uses Combine's `objectWillChange.debounce(...).sink`
/// pipeline. A future revision will swap in an `AsyncStream`-based
/// event pipeline.
@MainActor
@available(macOS 15, *)
final class WorkspaceFocusObserver: ObservableObject {

    @Published private(set) var current: ResolvedAgentSession?

    private weak var workspace: Workspace?
    private var cancellable: AnyCancellable?
    private var focusObserverTokens: [NSObjectProtocol] = []
    private let resolver: AgentSessionResolver
    private let storeWatcher: ClaudeHookSessionStore?
    private var lastEmittedKey: String?
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var retryGeneration = 0
    private var lastTerminalPanelId: UUID?

    init(
        workspace: Workspace,
        resolver: AgentSessionResolver = AgentSessionResolver(),
        watchStore: Bool = true
    ) {
        self.workspace = workspace
        self.resolver = resolver
        self.storeWatcher = watchStore ? ClaudeHookSessionStore() : nil

        cancellable = workspace.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recompute()
            }

        storeWatcher?.startWatching { [weak self] in
            DispatchQueue.main.async { self?.recompute() }
        }

        let names: [Notification.Name] = [
            .ghosttyDidFocusSurface,
            .ghosttyDidFocusTab,
            .ghosttyDidBecomeFirstResponderSurface
        ]
        focusObserverTokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recompute()
                }
            }
        }

        recompute()
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        for token in focusObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        focusObserverTokens.removeAll()
        storeWatcher?.stopWatching()
        pendingRetryWorkItem?.cancel()
        pendingRetryWorkItem = nil
    }

    private func recompute() {
        retryGeneration &+= 1
        recompute(retryBudget: 4, generation: retryGeneration)
    }

    private func recompute(retryBudget: Int, generation: Int) {
        guard let workspace else {
            updateIfChanged(nil)
            return
        }

        let focusedTerminal: TerminalPanel? = {
            guard let panelId = workspace.focusedPanelId else { return nil }
            return workspace.panels[panelId] as? TerminalPanel
        }()

        let selectedTerminalsInOtherPanes: [TerminalPanel] = {
            let controller = workspace.bonsplitController
            // Identify the pane currently holding the AgentX-ray panel
            // so we can ignore its selectedTab (it's the AgentXray
            // panel itself, not a terminal).
            let xrayPaneId = controller.allPaneIds.first { paneId in
                guard let tab = controller.selectedTab(inPane: paneId),
                      let panelId = workspace.panelIdFromSurfaceId(tab.id),
                      workspace.panels[panelId] is AgentXrayPanelHost else { return false }
                return true
            }
            return controller.allPaneIds.compactMap { paneId -> TerminalPanel? in
                if paneId == xrayPaneId { return nil }
                guard let tab = controller.selectedTab(inPane: paneId),
                      let panelId = workspace.panelIdFromSurfaceId(tab.id),
                      let terminal = workspace.panels[panelId] as? TerminalPanel
                else { return nil }
                return terminal
            }
        }()

        let trackedTerminal: TerminalPanel? = focusedTerminal
            ?? selectedTerminalsInOtherPanes.first
            ?? lastKnownTerminal()
            ?? bestCandidateTerminal(in: workspace)

        guard let terminal = trackedTerminal else {
            updateIfChanged(nil)
            return
        }
        rememberLastTerminal(terminal)

        let panelUUID = terminal.id

        let cwdHint: String? = {
            if !terminal.directory.isEmpty { return terminal.directory }
            if let req = terminal.requestedWorkingDirectory, !req.isEmpty {
                return req
            }
            return nil
        }()

        let ttyName = workspace.surfaceTTYNames[panelUUID]
        let resolved = resolver.resolve(
            workspaceID: workspace.id.uuidString,
            surfaceID: panelUUID.uuidString,
            cwdHint: cwdHint,
            ttyName: ttyName
        )
        if retryBudget > 0, resolved == nil || ttyName == nil {
            scheduleRetry(retryBudget: retryBudget - 1, generation: generation)
        }
        updateIfChanged(resolved)
    }

    private func scheduleRetry(retryBudget: Int, generation: Int) {
        pendingRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.retryGeneration else { return }
                self.recompute(retryBudget: retryBudget, generation: generation)
            }
        }
        pendingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    private func lastKnownTerminal() -> TerminalPanel? {
        guard let workspace, let id = lastTerminalPanelId else { return nil }
        return workspace.panels[id] as? TerminalPanel
    }

    private func rememberLastTerminal(_ terminal: TerminalPanel) {
        lastTerminalPanelId = terminal.id
    }

    private func bestCandidateTerminal(in workspace: Workspace) -> TerminalPanel? {
        var withCwd: TerminalPanel?
        var fallback: TerminalPanel?
        for (_, panel) in workspace.panels {
            guard let terminal = panel as? TerminalPanel else { continue }
            if !terminal.directory.isEmpty {
                if withCwd == nil { withCwd = terminal }
            } else if fallback == nil {
                fallback = terminal
            }
        }
        return withCwd ?? fallback
    }

    private func updateIfChanged(_ resolved: ResolvedAgentSession?) {
        let key = resolved.map { "\($0.agentKind.rawValue):\($0.sessionID):\($0.transcriptPath ?? "")" } ?? ""
        guard key != lastEmittedKey else { return }
        lastEmittedKey = key
        current = resolved
    }
}
