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
    /// Visible-turn filter mode. `.off` shows the entire transcript;
    /// `.snap` filters to chunks whose turn is currently visible in the
    /// paired terminal viewport (with implicit live tail at the bottom).
    @Published var syncMode: InspectorSyncMode = .snap {
        didSet {
            if syncMode == .snap && oldValue != .snap {
                // Initial filter pass: a notification might not fire for
                // a while if the terminal isn't actively scrolling. Pull
                // from the cached scrollbar state and compute now.
                recomputeVisibleTurnIds()
            } else if syncMode == .off {
                // Free scroll — view ignores visibleTurnIds, but clear it
                // so the published value reflects reality.
                if !visibleTurnIds.isEmpty {
                    visibleTurnIds = []
                }
            }
        }
    }

    /// User-chunk ids whose turn is currently visible in the paired
    /// terminal viewport. The view filters the chunk list to chunks
    /// belonging to these turns when `syncMode == .snap`. Empty when
    /// sync is off, the stream is empty, or no scrollbar state is
    /// available yet.
    @Published private(set) var visibleTurnIds: Set<String> = []

    /// Id of the trailing AI chunk while it is still streaming. Drives
    /// the pulsing `microbe.fill` glyph in the AI row header. Cleared
    /// when no AI chunk is the latest, or when the latest AI chunk's
    /// `endTime` is more than `streamingFreshnessWindow` in the past.
    @Published private(set) var streamingAIChunkId: String?

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
    /// Coalesces high-frequency scrollbar updates. Set when a notification
    /// matching the paired surface arrives; cleared when the trailing
    /// recompute fires. A single user scroll gesture at 120Hz collapses
    /// into one recompute per display frame instead of one per event.
    private var hasPendingScrollbarRecompute = false
    /// One-shot timer that re-checks `streamingAIChunkId` after the
    /// freshness window elapses. Cleared on every recompute.
    private var streamingFreshnessTimer: Timer?

    /// AI chunks whose `endTime` is within this many seconds of "now"
    /// are considered actively streaming. Picked to be loose enough that
    /// inter-line gaps during a turn don't stutter the pulse, tight
    /// enough that the pulse settles soon after the turn ends.
    private static let streamingFreshnessWindow: TimeInterval = 1.5

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
        // this hook to capture turn anchors for any newly-arrived chunks
        // and refresh the visible-turn filter + streaming-pulse state.
        streamCancellable = stream.objectWillChange
            .sink { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                // Anchor capture and downstream recomputes happen AFTER
                // the upstream change is applied; defer one tick so
                // `stream.chunks` reflects the new state.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.captureTurnAnchorsForNewChunks()
                    self.recomputeVisibleTurnIds()
                    self.recomputeStreamingAIChunkId()
                }
            }

        // Subscribe once for terminal-driven visible-turn updates. The
        // handler ignores notifications outside `.snap` mode so the
        // overhead is a single `==` per scroll event when the mode is
        // off. Notifications arrive at the terminal's render rate (up to
        // 120Hz on ProMotion); we coalesce them into a trailing 16ms
        // tick so a single user scroll gesture produces at most one
        // recompute per display frame.
        scrollbarObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.queueScrollbarUpdate(note)
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

    /// Notification entry point. Filters by surface and bails outside
    /// `.snap` mode in O(1). Coalesces multiple events that arrive within
    /// one ~16ms display frame into a single trailing recompute — VS
    /// Code uses the same pattern at 50ms in
    /// `markdown-language-features/preview-src/index.ts`.
    private func queueScrollbarUpdate(_ note: Notification) {
        guard case .live = mode, syncMode == .snap else { return }
        guard let surfaceUUIDString = resolvedSession?.surfaceId,
              let surfaceUUID = UUID(uuidString: surfaceUUIDString) else { return }
        guard let view = note.object as? GhosttyNSView,
              view.terminalSurface?.id == surfaceUUID else { return }
        guard !hasPendingScrollbarRecompute else { return }
        hasPendingScrollbarRecompute = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self else { return }
            self.hasPendingScrollbarRecompute = false
            // The cache has been updated by all notifications that
            // arrived during the throttle window; reading `latest(for:)`
            // gives the most recent state in one place.
            self.recomputeVisibleTurnIds()
        }
    }

    /// Compute the visible-turn id set from the cached scrollbar state of
    /// the paired terminal and publish it. Equality short-circuit on the
    /// `Set` keeps redundant scroll events within the same turn from
    /// invalidating the parent view body.
    func recomputeVisibleTurnIds() {
        guard case .live = mode else { return }
        guard syncMode == .snap else {
            if !visibleTurnIds.isEmpty { visibleTurnIds = [] }
            return
        }
        guard let surfaceUUIDString = resolvedSession?.surfaceId,
              let surfaceUUID = UUID(uuidString: surfaceUUIDString) else {
            if !visibleTurnIds.isEmpty { visibleTurnIds = [] }
            return
        }
        let scrollbar = ScrollbarStateCache.shared.latest(for: surfaceUUID)
        let snapshot = scrollbar.map(VisibleTurnScrollSnapshot.init)
        let computed = computeVisibleTurnIds(
            scrollbar: snapshot,
            chunks: stream.chunks,
            anchors: turnAnchorStore.orderedAnchors
        )
        if computed != visibleTurnIds {
            visibleTurnIds = computed
        }
    }

    /// Set `streamingAIChunkId` to the trailing AI chunk's id when that
    /// chunk is still being written to (per
    /// `streamingFreshnessWindow`), nil otherwise. Schedules a one-shot
    /// recheck after the freshness window so the pulse settles even if
    /// no further chunks land.
    func recomputeStreamingAIChunkId() {
        streamingFreshnessTimer?.invalidate()
        streamingFreshnessTimer = nil

        guard case .live = mode else {
            if streamingAIChunkId != nil { streamingAIChunkId = nil }
            return
        }
        let chunks = stream.chunks
        guard case let .ai(ai) = chunks.last else {
            if streamingAIChunkId != nil { streamingAIChunkId = nil }
            return
        }
        // Codex rollouts have no per-line timestamps (`endTime == nil`).
        // Treat them as "fresh while at the tail" — the next non-AI
        // chunk landing is what flips the pulse off in that case.
        let isFresh: Bool = {
            guard let endTime = ai.endTime else { return true }
            return Date().timeIntervalSince(endTime) < Self.streamingFreshnessWindow
        }()
        if isFresh {
            if streamingAIChunkId != ai.id {
                streamingAIChunkId = ai.id
            }
            // Re-check after the freshness window so we eventually clear
            // the pulse even if no further chunks land.
            let interval = Self.streamingFreshnessWindow + 0.1
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recomputeStreamingAIChunkId()
                }
            }
            streamingFreshnessTimer = timer
        } else {
            if streamingAIChunkId != nil { streamingAIChunkId = nil }
        }
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
        streamingFreshnessTimer?.invalidate()
        streamingFreshnessTimer = nil
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
