import AppKit
import CmuxAgentXray
import Combine
import Foundation
import OSLog

/// Workspace-scoped concrete `AgentXrayHost`. One per `Workspace`,
/// lazy-initialized via `Workspace.agentXrayWorkspaceHostLazy()` when
/// the first AgentX-ray panel is created in that workspace.
///
/// Composes every cmux-side capability the package needs:
///   - **Focus + session resolution** — bridges `Workspace.objectWillChange`
///     into an `AsyncStream<Void>` with 150 ms trailing-debounce; observes
///     three focus notifications; calls `AgentSessionResolver` and emits
///     a `ResolvedAgentSession?` via `@Published current`.
///   - **Scrollbar pipeline** — caches the latest `ScrollbarSnapshot` per
///     surface, observes `.ghosttyDidUpdateScrollbar`, multicasts to
///     subscribers.
///   - **Claude anchor pipeline** — observes `.cmuxClaudePromptSubmitted`,
///     multicasts to subscribers.
///   - **Per-panel routing** — holds a `[UUID: WeakAdapter]` registry so
///     `AgentXrayHost` per-panel methods (`openDetailTab(panelID:)`,
///     `updateTitle(panelID:)`, `flashAttention(panelID:)`) can dispatch
///     to the right `AgentXrayPanelAdapter`.
///
/// All AgentX-ray panels in one workspace share this single instance —
/// three panels do not produce three observers.
@MainActor
@available(macOS 15, *)
final class AgentXrayWorkspaceHost: AgentXrayHost {

    // MARK: - AgentXrayHost / identity

    var workspaceID: UUID { workspaceUUID }

    /// Host-side logger routing. `.debug` events go to the cmux
    /// `cmuxDebugLog` ring buffer (DEBUG builds only) so they show up
    /// in the existing `tail -f /tmp/cmux-debug-<tag>.log` dogfood
    /// loop. Higher levels (`.info`/`.notice`/`.warning`/`.error`)
    /// route to `os.Logger` for production retention + sysdiagnose
    /// pickup. Single static instance — `os.Logger` is a thread-safe
    /// value type and the routing has no per-host state.
    let logger: any AgentXrayLogger = AgentXrayWorkspaceLogger()

    private let workspaceUUID: UUID
    weak var workspace: Workspace?

    // MARK: - Per-panel registry

    /// Live `AgentXrayPanelAdapter`s in this workspace, keyed by their
    /// `Panel.id`. Adapters register themselves on init and deregister
    /// on close; entries are weakly held so a deallocated adapter
    /// vanishes without explicit cleanup.
    private var panelAdapters: [UUID: WeakPanelAdapterBox] = [:]

    /// In-flight detail-tab materialization tasks keyed by cache key.
    /// Prevents two near-simultaneous clicks on the same row from
    /// racing two writes against one path (and a third concurrent
    /// `openFileInPanel` reading the path). The materialize helpers
    /// register an entry before spawning the detached writer and
    /// remove it after the writer resolves; later callers `await`
    /// the existing entry instead of spawning a duplicate.
    var inflightMaterializations: [String: Task<URL?, Never>] = [:]

    func register(panel adapter: AgentXrayPanelAdapter) {
        panelAdapters[adapter.id] = WeakPanelAdapterBox(adapter)
    }

    func deregister(panelID: UUID) {
        panelAdapters.removeValue(forKey: panelID)
    }

    private func panelAdapter(forID id: UUID) -> AgentXrayPanelAdapter? {
        guard let box = panelAdapters[id] else { return nil }
        if let adapter = box.adapter { return adapter }
        // Lazily clean up dead entries so the dictionary doesn't grow.
        panelAdapters.removeValue(forKey: id)
        return nil
    }

    // MARK: - Focus + session resolution

    @Published private(set) var currentFocus: ResolvedAgentSession?

    private var workspaceBridge: AnyCancellable?
    private var observationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<Void>.Continuation?
    private var focusObserverTokens: [NSObjectProtocol] = []
    private let claudeStore: ClaudeHookSessionStore
    private let codexStore: CodexHookSessionStore
    private let storeWatcher: ClaudeHookSessionStore?
    private var lastEmittedKey: String?
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var retryGeneration = 0
    private var lastTerminalPanelId: UUID?

    // MARK: - Scrollbar pipeline

    private var scrollbarLatestBySurface: [UUID: ScrollbarSnapshot] = [:]
    private var scrollbarObserverToken: NSObjectProtocol?
    private var scrollbarSubscribers: [UUID: @MainActor (UUID) -> Void] = [:]

    // MARK: - Remote attach (path 3)

    private let remoteSessionStore: RemoteSessionStore
    private let remoteHomeResolver: RemoteHomeResolver
    /// Last-known per-tab SSH transport for the tracked terminal,
    /// inferred from the panel's process tree. Cleared on focus change.
    /// Reads happen during `recompute()` and `currentTerminalRemoteContext()`.
    private var inferredTransportByPanel: [UUID: SSHTransport?] = [:]

    // MARK: - Init

    init(
        workspace: Workspace,
        claudeStore: ClaudeHookSessionStore = ClaudeHookSessionStore(),
        codexStore: CodexHookSessionStore = CodexHookSessionStore(),
        remoteSessionStore: RemoteSessionStore = RemoteSessionStore(),
        remoteHomeResolver: RemoteHomeResolver? = nil,
        watchStore: Bool = true
    ) {
        self.workspaceUUID = workspace.id
        self.workspace = workspace
        self.claudeStore = claudeStore
        self.codexStore = codexStore
        self.storeWatcher = watchStore ? claudeStore : nil
        self.remoteSessionStore = remoteSessionStore
        self.remoteHomeResolver = remoteHomeResolver ?? RemoteHomeResolver()

        installFocusPipeline(workspace: workspace)
        installScrollbarObserver()
    }

    deinit {
        workspaceBridge?.cancel()
        streamContinuation?.finish()
        observationTask?.cancel()
        debounceTask?.cancel()
        for token in focusObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        if let scrollbarObserverToken {
            NotificationCenter.default.removeObserver(scrollbarObserverToken)
        }
        pendingRetryWorkItem?.cancel()
        // Clear AgentX-ray detail-tab file cache for this workspace
        // (rendered text + base64 → temp file materializations).
        // Per-launch root purge runs in
        // AppDelegate.applicationDidFinishLaunching; this catches the
        // workspace-close case so users don't see leftover files
        // when a workspace tears down without restarting the app.
        AgentXrayDetailFileCache.clear(workspaceID: workspaceUUID)
        // storeWatcher.stopWatching is implicitly handled when the
        // store is deallocated.
    }

    // MARK: - AgentXrayHost: focus

    func currentFocusedSession() -> ResolvedAgentSession? {
        currentFocus
    }

    func observeFocusChanges(
        _ handler: @escaping @MainActor () -> Void
    ) -> any AgentXrayCancellable {
        let combineCancellable = $currentFocus
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
        return HostCancellable(combine: combineCancellable)
    }

    // MARK: - AgentXrayHost: scrollbar

    func scrollbarSnapshot(forSurfaceID id: UUID) -> ScrollbarSnapshot? {
        scrollbarLatestBySurface[id]
    }

    func observeScrollbarChanges(
        _ handler: @escaping @MainActor (UUID) -> Void
    ) -> any AgentXrayCancellable {
        let key = UUID()
        scrollbarSubscribers[key] = handler
        return ClosureCancellable { [weak self] in
            self?.scrollbarSubscribers.removeValue(forKey: key)
        }
    }

    // MARK: - AgentXrayHost: claude anchor

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

    // MARK: - AgentXrayHost: live agent registry

    /// Live agent PIDs running in the given panel. Returns every
    /// process whose `CMUX_SURFACE_ID` env var matches `panelID` —
    /// includes the shell, the agent, and any descendants (cmux sets
    /// the env at shell spawn time and claude/codex inherit it).
    /// The resolver iterates the returned PIDs and the one with a
    /// matching hook record (claude/codex) wins.
    ///
    /// Backed by `CmuxTopProcessSnapshot.captureCached` rather than
    /// `Workspace.agentRuntimeState(forPanelId:)`. The latter only
    /// populates after the SessionStart hook fires `set_agent_pid`,
    /// so it's empty during the spawn-to-hook window AND after cmux
    /// app restart for surviving agents. Env-var-scoped detection
    /// catches every process the cmux app spawned, regardless of
    /// hook lifecycle.
    func agentPIDs(forPanelID panelID: UUID) -> [Int32] {
        let snapshot = CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: false,
            maximumAge: 1.5
        )
        return snapshot.pids(forCMUXSurfaceID: panelID).compactMap { pid in
            Int32(exactly: pid)
        }
    }

    /// Walk both hook stores looking for a record whose `pid` field
    /// matches. The two stores live at different on-disk paths
    /// (`~/.cmuxterm/{claude,codex}-hook-sessions.json`); we check
    /// both because the resolver doesn't know upfront which agent
    /// kind the PID belongs to.
    func findAgentHookRecord(byPID pid: Int32) -> AgentHookSessionMatch? {
        if let match = Self.scanHookStore(claudeStore.loadAll(), forPID: pid, agentKind: .claude) {
            return match
        }
        if let match = Self.scanHookStore(codexStore.loadAll(), forPID: pid, agentKind: .codex) {
            return match
        }
        return nil
    }

    /// Mirror cmux's `Workspace.restoredAgentSnapshotsByPanelId[panelId]`
    /// into the package's value-typed view. cmux pre-maps the
    /// restoration record onto the fresh panel UUID at restore time
    /// (see `RestorableAgentSessionIndex`), so this is panel-bound and
    /// unambiguous. Filtered to claude/codex; other kinds (grok,
    /// copilot, etc.) return nil — AgentX-ray doesn't render them.
    func restoredAgentSnapshot(forPanelID panelID: UUID) -> RestoredAgentSnapshot? {
        guard let workspace,
              let raw = workspace.restoredAgentSnapshotsByPanelId[panelID],
              let workingDirectory = raw.workingDirectory?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return nil
        }
        let kind: ResolvedAgentSession.AgentKind
        switch raw.kind {
        case .claude: kind = .claude
        case .codex:  kind = .codex
        default:      return nil
        }
        return RestoredAgentSnapshot(
            agentKind: kind,
            sessionID: raw.sessionId,
            workingDirectory: workingDirectory
        )
    }

    private static func scanHookStore(
        _ records: [String: AgentHookSessionRecord],
        forPID pid: Int32,
        agentKind: ResolvedAgentSession.AgentKind
    ) -> AgentHookSessionMatch? {
        for record in records.values {
            guard let recordPID = record.pid, Int32(recordPID) == pid else { continue }
            return AgentHookSessionMatch(
                agentKind: agentKind,
                sessionID: record.sessionId,
                cwd: record.cwd,
                transcriptPath: record.transcriptPath
            )
        }
        return nil
    }

    // MARK: - AgentXrayHost: per-panel routing

    @discardableResult
    func openDetailTab(
        content: DetailContent,
        fromPanelID panelID: UUID,
        activate: Bool
    ) -> AgentXrayPanel? {
        return openDetailTabRouting(
            content: content,
            fromPanelID: panelID,
            activate: activate
        )
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

    // MARK: - AgentXrayHost: open file in cmux panel

    /// Routes through cmux's standard URL-click pipeline:
    /// `Workspace.openFileSurfaces(...)` (`Sources/Panels/FilePreviewWorkspaceOpenSupport.swift:6`)
    /// dispatches by extension to `MarkdownPanel` (markdown-shaped) or
    /// `FilePreviewPanel` (everything else). Mirrors what
    /// `RightSidebarToolPanel.openFilePreview(_:)` does for the
    /// sidebar's file-list tap, minus the remote-workspace
    /// materialization branch (AgentX-ray detail content is local).
    @discardableResult
    func openFileInPanel(
        _ fileURL: URL,
        activate: Bool,
        reuseExisting: Bool
    ) -> UUID? {
        guard let workspace else { return nil }
        guard
            let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first
        else { return nil }
        let panels = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [fileURL.path(percentEncoded: false)],
            focus: activate,
            reuseExisting: reuseExisting
        )
        return panels.first?.id
    }

    // MARK: - AgentXrayHost: remote attach (path 3)

    func currentTerminalRemoteContext() -> RemoteAttachContext? {
        guard let panelID = lastTerminalPanelId else { return nil }
        return remoteContext(forPanelID: panelID)
    }

    func attachRemoteClaudeSessionID(_ sessionID: String?) {
        guard let panelID = lastTerminalPanelId,
              let workspace,
              let terminal = workspace.panels[panelID] as? TerminalPanel,
              let transport = sshTransportForTerminal(terminal) else {
            return
        }
        let cwd = terminal.directory
        let destination = transport.destination

        // Clearing is synchronous: just write nil + recompute.
        guard let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            remoteSessionStore.write(
                destination: destination,
                cwd: cwd,
                agentKind: .claude,
                sessionID: nil
            )
            recompute()
            return
        }

        // Setting may need to resolve $HOME first if the cache is cold.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.remoteHomeResolver.resolve(for: transport)
            } catch {
                self.logger.warning("RemoteHomeResolver: \(error.localizedDescription) for \(destination)")
                // Even if resolution fails, persist the id so the user
                // doesn't lose it; recompute will keep showing the
                // prompt because remoteHome stays empty in the context.
            }
            self.remoteSessionStore.write(
                destination: destination,
                cwd: cwd,
                agentKind: .claude,
                sessionID: trimmed
            )
            self.recompute()
        }
    }

    // MARK: - Remote attach: per-tab SSH inference

    /// Returns a `RemoteAttachContext` for the panel if its tracked
    /// terminal has an SSH transport (workspace-level OR per-tab
    /// inferred). The returned context's `remoteHome` is empty when the
    /// home hasn't been resolved yet — path 3 suppresses synthesis in
    /// that case but the panel still surfaces the prompt.
    private func remoteContext(forPanelID panelID: UUID) -> RemoteAttachContext? {
        guard let workspace,
              let terminal = workspace.panels[panelID] as? TerminalPanel,
              let transport = sshTransportForTerminal(terminal) else {
            return nil
        }
        let cwd = terminal.directory
        let cachedHome = remoteHomeResolver.cached(for: transport) ?? ""
        return RemoteAttachContext(
            sshTransport: transport,
            cwd: cwd,
            remoteHome: cachedHome,
            destination: transport.destination,
            agentKind: .claude
        )
    }

    /// Build an SSHTransport for the given terminal, preferring an
    /// inferred per-tab `ssh` subprocess (so AgentX-ray picks up "user
    /// typed `ssh box1` in this terminal" inside an otherwise-local
    /// workspace). Falls back to the workspace-level
    /// `WorkspaceRemoteConfiguration` when no ssh subprocess is found.
    /// Returns nil for fully-local terminals.
    private func sshTransportForTerminal(_ terminal: TerminalPanel) -> SSHTransport? {
        if let inferred = inferSSHTransportFromProcessTree(panelID: terminal.id) {
            inferredTransportByPanel[terminal.id] = inferred
            return inferred
        }
        inferredTransportByPanel[terminal.id] = nil
        return workspace?.agentXraySSHTransport()
    }

    /// Update the per-tab inference cache once per recompute so reads
    /// during `currentTerminalRemoteContext()` and the resolver
    /// closures stay consistent.
    private func rememberInferredTransport(forTerminal terminal: TerminalPanel) {
        // sshTransportForTerminal populates the cache as a side effect.
        _ = sshTransportForTerminal(terminal)
    }

    /// Walks the panel's PIDs (env-var-scoped, populated by cmux's CLI
    /// shell-spawn machinery), fetches each PID's argv via
    /// `CmuxTopProcessArguments`, and parses any whose argv[0] is `ssh`
    /// using `TerminalSSHSessionDetector.parseSSHCommandLine`. The
    /// most-recently-spawned ssh wins (innermost; matches the
    /// detector's nested-ssh precedent).
    private func inferSSHTransportFromProcessTree(panelID: UUID) -> SSHTransport? {
        let snapshot = CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: true,
            maximumAge: 1.5
        )
        let pidsInPanel = snapshot.pids(forCMUXSurfaceID: panelID)
        guard !pidsInPanel.isEmpty else { return nil }

        // Sort descending so the highest (most recent) PID wins on tie
        // breaks — matches the detector's "innermost ssh wins" rule.
        let sortedPIDs = pidsInPanel.sorted(by: >)
        for pid in sortedPIDs {
            guard let args = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: pid) else { continue }
            let argv = args.arguments
            guard !argv.isEmpty else { continue }
            // Skip non-ssh executables quickly. Match the file's basename
            // so `/usr/bin/ssh`, `/opt/homebrew/bin/ssh`, and bare `ssh`
            // all qualify.
            let exe = (argv[0] as NSString).lastPathComponent
            guard exe == "ssh" else { continue }
            guard let detected = TerminalSSHSessionDetector.parseSSHCommandLine(argv) else {
                continue
            }
            return SSHTransport(
                destination: detected.destination,
                port: detected.port,
                identityFile: detected.identityFile,
                controlPath: detected.controlPath
            )
        }
        return nil
    }

    // MARK: - Focus pipeline internals

    private func installFocusPipeline(workspace: Workspace) {
        // Bridge: Combine `objectWillChange` → AsyncStream<Void>. The
        // sink is the only Combine surface; the rest of the pipeline
        // is async/await.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.streamContinuation = continuation
        workspaceBridge = workspace.objectWillChange.sink { _ in
            continuation.yield()
        }

        // Consumer: trailing-debounce via Task cancellation. Each
        // incoming event cancels any pending recompute and starts a
        // new 150 ms sleep; only the last sleep survives, then fires
        // recompute().
        observationTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.recompute()
                }
            }
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
            // Identify every pane currently holding an AgentX-ray
            // panel so we can ignore their selectedTabs (they are
            // AgentX-ray panels, not terminals). Multiple AgentX-ray
            // panels can coexist in one workspace; we exclude them all.
            let xrayPaneIDs = Set(controller.allPaneIds.filter { paneId in
                guard let tab = controller.selectedTab(inPane: paneId),
                      let panelId = workspace.panelIdFromSurfaceId(tab.id) else {
                    return false
                }
                return workspace.panels[panelId] is AgentXrayPanelAdapter
            })
            return controller.allPaneIds.compactMap { paneId -> TerminalPanel? in
                if xrayPaneIDs.contains(paneId) { return nil }
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

        // Refresh per-tab SSH inference + last-tracked-terminal cache
        // so the resolver's path-3 closures see consistent data.
        rememberInferredTransport(forTerminal: terminal)

        let resolver = AgentSessionResolver(
            agentPIDsForPanel: { [weak self] panelID in
                self?.agentPIDs(forPanelID: panelID) ?? []
            },
            hookRecordForPID: { [weak self] pid in
                self?.findAgentHookRecord(byPID: pid)
            },
            restoredSnapshotForPanel: { [weak self] panelID in
                self?.restoredAgentSnapshot(forPanelID: panelID)
            },
            remoteContextForPanel: { [weak self] panelID in
                self?.remoteContext(forPanelID: panelID)
            },
            remoteSessionForPanel: { [weak self] _, ctx in
                self?.remoteSessionStore.read(
                    destination: ctx.destination,
                    cwd: ctx.cwd,
                    agentKind: ctx.agentKind
                )
            }
        )
        let resolved = resolver.resolve(
            panelID: panelUUID,
            workspaceID: workspace.id.uuidString
        )
        #if DEBUG
        let pidCount = agentPIDs(forPanelID: panelUUID).count
        let hasSnapshot = restoredAgentSnapshot(forPanelID: panelUUID) != nil
        cmuxDebugLog("""
            agentXray.focus.resolve panel=\(panelUUID.uuidString.prefix(8)) \
            agentPIDCount=\(pidCount) hasRestoredSnapshot=\(hasSnapshot) \
            kind=\(resolved?.agentKind.rawValue ?? "nil") \
            sessionPresent=\(resolved?.sessionID != nil) \
            transcriptPathPresent=\(resolved?.transcriptPath != nil)
            """)
        #endif
        if retryBudget > 0, resolved == nil {
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
        currentFocus = resolved
    }

    // MARK: - Scrollbar pipeline internals

    private func installScrollbarObserver() {
        scrollbarObserverToken = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleScrollbarNotification(note)
            }
        }
    }

    private func handleScrollbarNotification(_ note: Notification) {
        guard let scrollbar = note.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        guard let view = note.object as? GhosttyNSView,
              let surfaceID = view.terminalSurface?.id else {
            return
        }
        scrollbarLatestBySurface[surfaceID] = ScrollbarSnapshot(
            total: scrollbar.total,
            offset: scrollbar.offset,
            len: scrollbar.len
        )
        for handler in scrollbarSubscribers.values {
            handler(surfaceID)
        }
    }
}

// MARK: - Cancellable helpers

/// Concrete `AgentXrayCancellable` for the host-protocol's observation
/// methods. Wraps either an `AnyCancellable` (for Combine publishers)
/// or a `NotificationCenter` observer token. `cancel()` is idempotent.
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

/// `AgentXrayCancellable` backed by an arbitrary closure. Used by the
/// scrollbar pipeline to cancel a per-subscriber dictionary entry.
@MainActor
@available(macOS 15, *)
private final class ClosureCancellable: AgentXrayCancellable {
    private var closure: (() -> Void)?

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    func cancel() {
        closure?()
        closure = nil
    }

    deinit {
        closure?()
    }
}

/// Weak box for the per-panel registry. Lets the workspace host
/// reference panel adapters without keeping them alive past
/// `AgentXrayPanelAdapter.close()`.
@MainActor
@available(macOS 15, *)
private struct WeakPanelAdapterBox {
    weak var adapter: AgentXrayPanelAdapter?

    init(_ adapter: AgentXrayPanelAdapter) {
        self.adapter = adapter
    }
}

// MARK: - Workspace flash request bridging

@available(macOS 15, *)
extension Workspace {
    /// Bumps the workspace's flash pipeline for the given panel.
    /// Lightweight extension shim so `AgentXrayWorkspaceHost` can route
    /// AttentionFlashReason → WorkspaceAttentionFlashReason without
    /// reaching directly into Workspace internals.
    fileprivate func requestFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        guard let panel = panels[panelId] else { return }
        panel.triggerFlash(reason: reason)
    }

    /// Build an `SSHTransport` from the workspace's
    /// `WorkspaceRemoteConfiguration` for AgentX-ray's remote tail
    /// pipeline. Returns nil for local workspaces and for remote
    /// workspaces whose configuration lacks a usable destination.
    ///
    /// The ControlPath is extracted from the configuration's
    /// `sshOptions` and passed through so AgentX-ray's `ssh exec`
    /// subprocesses (`echo $HOME` and `tail -F`) ride cmux's existing
    /// ControlMaster — sub-second auth-free attach. Mirrors the
    /// precedent in `WorkspaceRemoteSSHBatchCommandBuilder`.
    fileprivate func agentXraySSHTransport() -> SSHTransport? {
        guard let config = remoteConfiguration else { return nil }
        let dest = config.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return nil }
        let controlPath = AgentXraySSHOptions.controlPath(in: config.sshOptions)
        return SSHTransport(
            destination: dest,
            port: config.port,
            identityFile: config.identityFile,
            controlPath: controlPath
        )
    }
}

// MARK: - SSH option helpers

/// Tiny value-typed namespace for sshOption parsing. Mirrors the
/// behaviour of `WorkspaceRemoteSSHBatchCommandBuilder`'s private
/// `sshOptionValue(named:in:)` so AgentX-ray can extract the workspace's
/// ControlPath without touching upstream-private helpers.
@available(macOS 15, *)
enum AgentXraySSHOptions {
    /// Returns the `ControlPath` template (e.g. `/tmp/cmux-ssh-501-%C`)
    /// from a `sshOptions` array, or nil if absent / empty / disabled
    /// via `none`.
    static func controlPath(in options: [String]) -> String? {
        guard let raw = sshOptionValue(named: "ControlPath", in: options) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return trimmed
    }

    private static func sshOptionValue(named name: String, in options: [String]) -> String? {
        let loweredName = name.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let equals = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard key.lowercased() == loweredName else { continue }
                let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

// MARK: - Logger adapter

/// Concrete `AgentXrayLogger` for the cmux app target. Routes by
/// level:
///   - `.debug` → `cmuxDebugLog(...)` (DEBUG builds only) so dev-time
///     `tail -f /tmp/cmux-debug-<tag>.log` keeps working.
///   - `.info` / `.notice` / `.warning` / `.error` → `os.Logger`
///     subsystem `com.cmuxterm.app`, category `AgentXray`. Visible in
///     Console.app and persisted into sysdiagnose archives so
///     production engineers can investigate user reports.
///
/// All interpolated strings forward with `.public` privacy because the
/// package's `AgentXrayLogger` protocol erases per-interpolation
/// privacy at the seam. Callers must not interpolate raw user content
/// (transcript bodies, file paths containing user dirs) per the
/// protocol's documented privacy convention.
@available(macOS 15, *)
struct AgentXrayWorkspaceLogger: AgentXrayLogger {
    private static let osLog = Logger(subsystem: "com.cmuxterm.app", category: "AgentXray")

    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        cmuxDebugLog("agentXray: \(message())")
        #endif
    }

    func info(_ message: @autoclosure () -> String) {
        let body = message()
        Self.osLog.info("\(body, privacy: .public)")
    }

    func notice(_ message: @autoclosure () -> String) {
        let body = message()
        Self.osLog.notice("\(body, privacy: .public)")
    }

    func warning(_ message: @autoclosure () -> String) {
        let body = message()
        Self.osLog.warning("\(body, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let body = message()
        Self.osLog.error("\(body, privacy: .public)")
    }
}
