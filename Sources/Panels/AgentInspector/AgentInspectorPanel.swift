import AppKit
import Combine
import Foundation

/// A side-by-side companion panel that mirrors the Claude Code or Codex
/// session running in the workspace's currently focused terminal surface.
///
/// Operates in two modes:
/// - `.live` (default): auto-attaches to the focused terminal's hook session
///   via `FocusedSurfaceObserver`, opens the transcript via `JSONLTail`,
///   builds chunks via `ClaudeChunkBuilder`, and exposes the live chunk list.
/// - `.detail(content:)`: renders one frozen `AgentInspectorDetailContent`
///   without streaming or auto-attach. Used for the "↗ Open detail" route in
///   the transcript renderer when an expandable section overflows the inline
///   cap. Detail panels open as sibling tabs in the same pane.
@MainActor
final class AgentInspectorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .agentInspector

    /// The workspace this panel belongs to.
    private(set) weak var workspace: Workspace?
    var workspaceId: UUID

    enum Mode: Equatable {
        case live
        case detail(content: AgentInspectorDetailContent)
    }

    let mode: Mode

    var displayTitle: String {
        switch mode {
        case .live:
            if let session = focusedSurfaceObserver?.current {
                return String(
                    localized: "agentInspector.title.attached",
                    defaultValue: "Inspector — \(session.sessionId.prefix(8))"
                )
            }
            return String(
                localized: "agentInspector.title",
                defaultValue: "Agent Inspector"
            )
        case .detail(let content):
            return content.title
        }
    }

    var displayIcon: String? {
        switch mode {
        case .live: return "chart.bar.doc.horizontal"
        case .detail: return "doc.text"
        }
    }

    @Published private(set) var focusFlashToken: Int = 0
    @Published private(set) var resolvedSession: ResolvedAgentSession?
    /// User-selected scroll-sync mode. `.followTail` matches the
    /// pre-Phase-B behaviour. `.syncToTerminal` engages the
    /// `TurnAnchorStore`-backed bridge.
    @Published var syncMode: InspectorSyncMode = .followTail {
        didSet {
            if syncMode == .syncToTerminal && oldValue != .syncToTerminal {
                // Initial alignment: a notification might not fire for a
                // while if the terminal isn't actively scrolling. Pull
                // from the cached scrollbar state and align right now.
                alignToCurrentTerminalScrollState()
            }
        }
    }
    /// Chunk id the view should programmatically scroll to. The view
    /// observes this, calls `proxy.scrollTo(...)`, and clears it back to
    /// nil so subsequent equal values re-trigger.
    @Published var pendingScrollTarget: PendingScrollTarget?

    /// One-off command issued by the bridge to ask the view to scroll to a
    /// specific chunk. Carries an opaque token so the view can dedupe
    /// even when the same chunk id repeats. `anchorPoint` controls which
    /// part of the row aligns with the viewport (top for mid-turn snaps,
    /// bottom for tail-following).
    struct PendingScrollTarget: Equatable {
        let chunkId: String
        let token: UInt64
        let anchorPoint: ScrollAnchor

        enum ScrollAnchor: Equatable {
            case top
            case bottom
        }
    }

    /// Turn anchors keyed by user-chunk id. Populated as new chunks land
    /// in the stream by reading `ScrollbarStateCache` for the paired
    /// surface.
    let turnAnchorStore = TurnAnchorStore()

    /// Transcript stream — live `AgentChunk` snapshots. Empty in detail mode.
    let stream = TranscriptStream()

    private var focusedSurfaceObserver: FocusedSurfaceObserver?
    private var sessionCancellable: AnyCancellable?
    private var streamCancellable: AnyCancellable?
    private var scrollbarObserver: NSObjectProtocol?
    /// Monotonic token assigned to every programmatic scroll. Lets the view
    /// dedupe identical chunk ids without losing repeat-tap intent.
    private var nextScrollToken: UInt64 = 1

    init(workspace: Workspace) {
        self.id = UUID()
        self.workspace = workspace
        self.workspaceId = workspace.id
        self.mode = .live

        let observer = FocusedSurfaceObserver(workspace: workspace)
        focusedSurfaceObserver = observer
        sessionCancellable = observer.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.handleSessionChange(session)
            }

        // SwiftUI's @ObservedObject only tracks the immediate object's
        // @Published properties — it does NOT auto-track nested ones like
        // `panel.stream.chunks`. Forward stream updates into our own
        // objectWillChange so the inspector view re-renders when chunks /
        // lineCount change after a tab switch resets the stream. Also use
        // this hook to capture turn anchors for any newly-arrived chunks.
        streamCancellable = stream.objectWillChange
            .sink { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                // Anchor capture happens AFTER the upstream change is
                // applied; defer one tick so `stream.chunks` reflects the
                // new state.
                DispatchQueue.main.async { [weak self] in
                    self?.captureTurnAnchorsForNewChunks()
                }
            }

        // Subscribe once for terminal-driven scroll sync. The handler
        // ignores notifications outside `.syncToTerminal` mode so the
        // overhead is a single `==` per scroll event when the mode is off.
        scrollbarObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleScrollbarUpdate(note)
            }
        }
    }

    /// Detail-mode initializer. Renders a static, non-streaming snapshot of
    /// one expanded section from the live inspector.
    init(workspace: Workspace, detail: AgentInspectorDetailContent) {
        self.id = UUID()
        self.workspace = workspace
        self.workspaceId = workspace.id
        self.mode = .detail(content: detail)
        // No observer / no stream attach — detail panels are frozen.
    }

    private func handleSessionChange(_ session: ResolvedAgentSession?) {
        resolvedSession = session
        stream.attach(session: session)
        // Re-scope the anchor store on session change. New session ⇒ drop
        // anchors from the previous turn timeline.
        if let session,
           let workspaceId = UUID(uuidString: session.workspaceId),
           let surfaceId = UUID(uuidString: session.surfaceId) {
            turnAnchorStore.setSurface(workspaceId: workspaceId, surfaceId: surfaceId)
        } else {
            turnAnchorStore.setSurface(workspaceId: nil, surfaceId: nil)
        }
        objectWillChange.send()
    }

    /// Walk the current chunks and record anchors for any new turn we
    /// haven't seen before. Idempotent via `recordTurnStart` skipping
    /// existing entries. Pairs the most-recent unpaired user chunk with
    /// the next AI chunk.
    ///
    /// **Skips anchor recording when no scrollbar update has been seen yet
    /// for the surface.** Otherwise we would record `terminalRow: 0` for
    /// every chunk that pre-existed when the inspector opened (history
    /// loaded from disk before any Ghostty scroll event), which would
    /// cause `anchorContaining(row:)` to match those historical chunks
    /// for any visible row. Anchors only get populated for turns that
    /// happen *while the inspector is open and the terminal is alive*.
    /// Sync mode falls back to a proportional mapping for unanchored
    /// chunks.
    private func captureTurnAnchorsForNewChunks() {
        guard case .live = mode,
              let surfaceUUIDString = resolvedSession?.surfaceId,
              let surfaceUUID = UUID(uuidString: surfaceUUIDString) else { return }
        let chunks = stream.chunks
        guard !chunks.isEmpty else { return }
        guard let scrollbar = ScrollbarStateCache.shared.latest(for: surfaceUUID) else {
            // No scrollbar info yet — don't pollute the store with row=0
            // anchors that would shadow real turns once they arrive.
            return
        }

        var lastUnpairedUserId: String? = {
            for anchor in turnAnchorStore.orderedAnchors.reversed() {
                if anchor.aiChunkId == nil { return anchor.userChunkId }
            }
            return nil
        }()

        for chunk in chunks {
            switch chunk {
            case .user(let user):
                if turnAnchorStore.anchor(forChunkId: user.id) == nil {
                    turnAnchorStore.recordTurnStart(
                        userChunkId: user.id,
                        terminalRow: scrollbar.total
                    )
                }
                lastUnpairedUserId = user.id
            case .ai(let ai):
                if let userId = lastUnpairedUserId {
                    turnAnchorStore.pairAIChunk(userChunkId: userId, aiChunkId: ai.id)
                    lastUnpairedUserId = nil
                }
            case .system, .compact:
                break
            }
        }
    }

    /// React to `ghosttyDidUpdateScrollbar` from the paired terminal: in
    /// `.syncToTerminal` mode, recompute alignment from the new scrollbar
    /// state. Filtered by surface so a noisy unrelated terminal doesn't
    /// jolt the inspector.
    private func handleScrollbarUpdate(_ note: Notification) {
        guard case .live = mode, syncMode == .syncToTerminal else { return }
        guard let surfaceUUIDString = resolvedSession?.surfaceId,
              let surfaceUUID = UUID(uuidString: surfaceUUIDString) else { return }
        guard let view = note.object as? GhosttyNSView,
              view.terminalSurface?.id == surfaceUUID else { return }
        alignToCurrentTerminalScrollState()
    }

    /// Compute a scroll target for the inspector based on the cached
    /// scrollbar state of the paired terminal. Three alignment regimes:
    ///
    /// 1. **At-bottom snap**: when the terminal viewport reaches the tail
    ///    of the scrollback, scroll the inspector to its last chunk's
    ///    bottom. Matches the `followTail` feel.
    /// 2. **Anchored**: if a `TurnAnchor` exists whose
    ///    `terminalRowAtSubmit` is `≤ scrollbar.offset`, scroll to that
    ///    turn's chunk header. The natural "this turn is currently
    ///    visible in the terminal" mapping.
    /// 3. **Proportional fallback**: when no anchor matches (e.g. fresh
    ///    session with no turns yet, or pre-inspector-open turns), pick
    ///    the chunk at the same scroll fraction as the terminal.
    ///
    /// Issued via `pendingScrollTarget` so the view's `.onChange` can
    /// drive the actual `proxy.scrollTo(...)` and the panel does not
    /// touch SwiftUI scrolling primitives directly.
    func alignToCurrentTerminalScrollState() {
        guard case .live = mode,
              let surfaceUUIDString = resolvedSession?.surfaceId,
              let surfaceUUID = UUID(uuidString: surfaceUUIDString) else { return }
        guard let scrollbar = ScrollbarStateCache.shared.latest(for: surfaceUUID) else { return }

        let chunks = stream.chunks
        guard !chunks.isEmpty else { return }

        // (1) At-bottom snap.
        let viewportEnd = scrollbar.offset &+ scrollbar.len
        let isAtBottom = scrollbar.total == 0 || viewportEnd >= scrollbar.total
        if isAtBottom, let last = chunks.last {
            publishScrollTarget(chunkId: last.id, anchor: .bottom)
            return
        }

        // (2) Anchored match.
        if let anchor = turnAnchorStore.anchorContaining(row: scrollbar.offset) {
            let chunkId = anchor.aiChunkId ?? anchor.userChunkId
            publishScrollTarget(chunkId: chunkId, anchor: .top)
            return
        }

        // (3) Proportional fallback over user chunks (turns are the
        //     natural alignment unit; user chunks delimit them).
        let userIds = chunks.compactMap { chunk -> String? in
            if case .user(let u) = chunk { return u.id }
            return nil
        }
        let pool = userIds.isEmpty ? chunks.map(\.id) : userIds
        guard !pool.isEmpty else { return }

        // Denominator = total scrollable rows. Avoid div-by-zero when the
        // scrollback fits entirely in the viewport.
        let scrollableRows: UInt64 = scrollbar.total > scrollbar.len
            ? scrollbar.total - scrollbar.len
            : 0
        let fraction: Double = scrollableRows == 0
            ? 0
            : min(1.0, Double(scrollbar.offset) / Double(scrollableRows))
        let lastIndex = pool.count - 1
        let idx = min(lastIndex, max(0, Int((Double(lastIndex) * fraction).rounded())))
        publishScrollTarget(chunkId: pool[idx], anchor: .top)
    }

    private func publishScrollTarget(chunkId: String, anchor: PendingScrollTarget.ScrollAnchor) {
        let token = nextScrollToken
        nextScrollToken &+= 1
        pendingScrollTarget = PendingScrollTarget(chunkId: chunkId, token: token, anchorPoint: anchor)
    }

    /// View calls this after consuming `pendingScrollTarget` so a re-issue
    /// of the same chunk id (e.g. user keeps scrolling within the same
    /// turn) doesn't lose the next intent.
    func consumePendingScrollTarget() {
        pendingScrollTarget = nil
    }

    // MARK: - Panel protocol

    func focus() {
        // Phase 1: no internal focus state to claim — the row list owns its
        // own selection state via SwiftUI focus.
    }

    func unfocus() {}

    func close() {
        focusedSurfaceObserver?.stop()
        focusedSurfaceObserver = nil
        sessionCancellable?.cancel()
        sessionCancellable = nil
        streamCancellable?.cancel()
        streamCancellable = nil
        if let scrollbarObserver {
            NotificationCenter.default.removeObserver(scrollbarObserver)
        }
        scrollbarObserver = nil
        stream.attach(session: nil)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Detail-panel routing

    /// Called when a chunk row triggers `↗ Open detail` because the requested
    /// expandable section exceeded the inline cap. Looks up the chunk in the
    /// stream, resolves the requested content slice, and asks the workspace
    /// to add a sibling detail tab in the same pane.
    ///
    /// No-op in `.detail` mode (detail panels don't host a live stream).
    func openDetail(request: InspectorDetailRequest) {
        guard case .live = mode else { return }
        guard let workspace else { return }
        let chunkId = request.chunkId
        guard let chunk = stream.chunks.first(where: { $0.id == chunkId }) else { return }
        guard let content = AgentInspectorDetailContent.resolve(request: request, chunk: chunk) else {
            return
        }
        workspace.openAgentInspectorDetail(content: content, fromInspectorPanelId: id)
    }
}

private extension InspectorDetailRequest {
    var chunkId: String {
        switch self {
        case .userPrompt(let id),
             .thinking(let id),
             .systemOutput(let id):
            return id
        case .toolInput(let chunkId, _),
             .toolResult(let chunkId, _):
            return chunkId
        }
    }
}
