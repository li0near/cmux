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
    private weak var workspace: Workspace?

    // MARK: - Per-panel registry

    /// Live `AgentXrayPanelAdapter`s in this workspace, keyed by their
    /// `Panel.id`. Adapters register themselves on init and deregister
    /// on close; entries are weakly held so a deallocated adapter
    /// vanishes without explicit cleanup.
    private var panelAdapters: [UUID: WeakPanelAdapterBox] = [:]

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
    private let resolver: AgentSessionResolver
    private let storeWatcher: ClaudeHookSessionStore?
    private var lastEmittedKey: String?
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var retryGeneration = 0
    private var lastTerminalPanelId: UUID?

    // MARK: - Scrollbar pipeline

    private var scrollbarLatestBySurface: [UUID: ScrollbarSnapshot] = [:]
    private var scrollbarObserverToken: NSObjectProtocol?
    private var scrollbarSubscribers: [UUID: @MainActor (UUID) -> Void] = [:]

    // MARK: - Init

    init(
        workspace: Workspace,
        resolver: AgentSessionResolver = AgentSessionResolver(),
        watchStore: Bool = true
    ) {
        self.workspaceUUID = workspace.id
        self.workspace = workspace
        self.resolver = resolver
        self.storeWatcher = watchStore ? ClaudeHookSessionStore() : nil

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

    // MARK: - AgentXrayHost: per-panel routing

    @discardableResult
    func openDetailTab(content: DetailContent, fromPanelID panelID: UUID) -> AgentXrayPanel? {
        guard let workspace else { return nil }
        return workspace.openAgentXrayDetail(
            content: content,
            fromPanelID: panelID
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

        let cwdHint: String? = {
            if !terminal.directory.isEmpty { return terminal.directory }
            if let req = terminal.requestedWorkingDirectory, !req.isEmpty {
                return req
            }
            return nil
        }()

        let resolved = resolver.resolve(
            workspaceID: workspace.id.uuidString,
            surfaceID: panelUUID.uuidString,
            cwdHint: cwdHint
        )
        #if DEBUG
        cmuxDebugLog("""
            agentXray.focus.resolve panel=\(panelUUID.uuidString.prefix(8)) \
            cwdHasValue=\(cwdHint != nil) \
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
