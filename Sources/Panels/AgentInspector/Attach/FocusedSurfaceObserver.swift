import Combine
import Foundation

/// Watches a workspace for changes to its focused terminal surface and emits
/// the resolved Claude/Codex session whenever the focused terminal changes.
///
/// The cheap approach: subscribe to `Workspace.objectWillChange`, debounce a
/// few ms, then re-derive `focusedPanelId` and look up the session. Workspace
/// publishes for many reasons (selection, layout, color, …) so the debounce
/// keeps us from thrashing. We only emit when the resolved session actually
/// differs from the last one, so subscribers don't see noise.
@MainActor
final class FocusedSurfaceObserver: ObservableObject {

    @Published private(set) var current: ResolvedAgentSession?

    private weak var workspace: Workspace?
    private var cancellable: AnyCancellable?
    private var focusObserverTokens: [NSObjectProtocol] = []
    private let resolver: AgentSessionResolver
    private let storeWatcher: ClaudeHookSessionStore?
    private var lastEmittedKey: String?
    /// Last focused TerminalPanel; we keep this so the inspector doesn't
    /// detach when the user clicks the inspector pane itself to scroll.
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

        // Watch the store file too — the focused surface might not change
        // but its sessionId can (e.g. /clear creates a new session entry).
        storeWatcher?.startWatching { [weak self] in
            DispatchQueue.main.async { self?.recompute() }
        }

        // cmux posts three notifications around tab/surface focus, each at
        // a different moment in the click sequence:
        //
        //   .ghosttyDidFocusTab — when bonsplit's selectedTab changes.
        //     Fires on the FIRST click on a tab title even if keyboard
        //     focus stays on another pane (e.g. user clicks a left-pane
        //     tab while the inspector pane has firstResponder). Without
        //     this, the inspector would only follow on the second click
        //     when the user clicks into the terminal area itself.
        //   .ghosttyDidFocusSurface — when a surface gains keyboard focus.
        //   .ghosttyDidBecomeFirstResponderSurface — when a surface becomes
        //     firstResponder (covers pane-level focus changes the other
        //     two miss).
        //
        // All three are zero-cost subscribers; we just dedupe via
        // `updateIfChanged` so subscribers don't see redundant emissions.
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
                self?.recompute()
            }
        }

        // Seed initial value.
        recompute()
    }

    deinit {
        // storeWatcher.stopWatching is idempotent and called from its deinit.
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        for token in focusObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        focusObserverTokens.removeAll()
        storeWatcher?.stopWatching()
    }

    private func recompute() {
        guard let workspace else {
            updateIfChanged(nil)
            return
        }

        // Resolution priority:
        //   1. The currently focused panel, if it's a TerminalPanel —
        //      the user is actively typing into that surface.
        //   2. Otherwise, the SELECTED tab in each pane. When the user
        //      clicks a different terminal tab on the left while the
        //      inspector pane on the right keeps focus, bonsplit's
        //      `focusedPaneId` doesn't change, but the left pane's
        //      `selectedTab` does — so iterating selected tabs picks up
        //      the change. Among multiple selected terminals, prefer the
        //      one most recently switched to (tracked across recomputes).
        //   3. Otherwise, any terminal panel in the workspace.
        let focusedTerminal: TerminalPanel? = {
            guard let panelId = workspace.focusedPanelId else { return nil }
            return workspace.panels[panelId] as? TerminalPanel
        }()

        let selectedTerminalsInOtherPanes: [TerminalPanel] = {
            let controller = workspace.bonsplitController
            let inspectorPaneId = controller.allPaneIds.first { paneId in
                guard let tab = controller.selectedTab(inPane: paneId),
                      let panelId = workspace.panelIdFromSurfaceId(tab.id),
                      workspace.panels[panelId] is AgentInspectorPanel else { return false }
                return true
            }
            return controller.allPaneIds.compactMap { paneId -> TerminalPanel? in
                if paneId == inspectorPaneId { return nil }
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

        // cmux's `surfaceId` is overloaded: hook stores, lifecycle events,
        // and the `CMUX_SURFACE_ID` env all refer to the PANEL UUID
        // (== TerminalSurface.id == TerminalPanel.id), NOT the bonsplit
        // TabID. `Workspace.surfaceIdFromPanelId(_:)` returns the bonsplit
        // TabID, which is a different UUID. Use `terminal.id` directly so
        // the scanner / hook lookup keys match what cmux actually injects.
        // See `Sources/RestorableAgentSession.swift:1012-1013` for the
        // upstream pattern.
        let panelUUID = terminal.id

        // Prefer the live OSC-reported cwd; fall back to the launch cwd
        // (`requestedWorkingDirectory`) when the shell hasn't reported one
        // yet — this matters on first launch before any prompt has run.
        let cwdHint: String? = {
            if !terminal.directory.isEmpty { return terminal.directory }
            if let req = terminal.requestedWorkingDirectory, !req.isEmpty {
                return req
            }
            return nil
        }()

        let resolved = resolver.resolve(
            workspaceId: workspace.id.uuidString,
            surfaceId: panelUUID.uuidString,
            cwdHint: cwdHint
        )
        updateIfChanged(resolved)
    }

    private func lastKnownTerminal() -> TerminalPanel? {
        guard let workspace, let id = lastTerminalPanelId else { return nil }
        return workspace.panels[id] as? TerminalPanel
    }

    private func rememberLastTerminal(_ terminal: TerminalPanel) {
        lastTerminalPanelId = terminal.id
    }

    /// Pick the most likely terminal in the workspace. Prefers a terminal
    /// with a non-empty cwd (an agent running there is more likely), then
    /// any terminal at all.
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
        let key = resolved.map { "\($0.agentKind.rawValue):\($0.sessionId):\($0.transcriptPath ?? "")" } ?? ""
        guard key != lastEmittedKey else { return }
        lastEmittedKey = key
        current = resolved
    }
}
