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
                recomputeVisibleTurnFilter()
            } else if syncMode == .off {
                // Free scroll — view ignores visibleTurnFilter, but
                // reset it so the published value reflects reality.
                if visibleTurnFilter != .all {
                    visibleTurnFilter = .all
                }
            }
        }
    }

    /// Three-way visible-turn filter computed by
    /// `computeVisibleTurnFilter`. The view switches on this:
    ///   - `.all` → render every chunk (free scroll)
    ///   - `.turns(set)` → render chunks whose containing turn's
    ///     user-chunk-id is in `set` (anchored zone)
    ///   - `.preAnchored` → render chunks whose containing turn has
    ///     no anchor (pre-inspector zone, free scroll within history)
    @Published private(set) var visibleTurnFilter: VisibleTurnFilter = .all

    /// Id of the trailing AI chunk while it is still streaming. Drives
    /// the pulsing `microbe.fill` glyph in the AI row header. Cleared
    /// when no AI chunk is the latest, or when the latest AI chunk's
    /// `endTime` is more than `streamingFreshnessWindow` in the past.
    @Published private(set) var streamingAIChunkId: String?

    /// Phase C: rewound-branch visibility toggle. Persisted via
    /// UserDefaults (key `agentInspector.rewindVisibility`).
    @Published var rewindVisibility: InspectorRewindVisibility = .link {
        didSet {
            UserDefaults.standard.set(
                rewindVisibility.rawValue,
                forKey: "agentInspector.rewindVisibility"
            )
        }
    }

    /// Phase C: per-turn auto-expand toggle. Persisted via UserDefaults
    /// (key `agentInspector.expansionMode`).
    @Published var expansionMode: InspectorExpansionMode = .allCollapsed {
        didSet {
            UserDefaults.standard.set(
                expansionMode.rawValue,
                forKey: "agentInspector.expansionMode"
            )
        }
    }

    /// Phase D iter 4: panel-level global expansion state. Bulk
    /// "Collapse all" / "Expand all" actions advance this one step
    /// per click. Combined with `expansionOverrides`, this is the
    /// **single source of truth** for every row's bulk-managed
    /// expansion — rows hold no `@State` for it. The panel view
    /// resolves `(bulkState.stage, expansionOverrides)` into per-id
    /// booleans, bakes them into `ChunkRowSnapshot`, and rows just
    /// render the snapshot. One publish here → one synchronous body
    /// pass in the panel view → all rows update with new heights in
    /// the same frame. No `.onChange` cascade, no off-screen lag, no
    /// LazyVStack height estimation race against `proxy.scrollTo`.
    ///
    /// State machine (each click advances exactly one step):
    ///
    ///   Collapse all click: fullyExpanded → topLevelExpanded → fullyCollapsed → fullyCollapsed
    ///   Expand   all click: fullyCollapsed → topLevelExpanded → fullyExpanded → fullyExpanded
    ///
    /// Initial value is `.topLevelExpanded` to match the design
    /// default (AI chunk header open, sub-items closed).
    @Published private(set) var bulkState: BulkExpansionState = BulkExpansionState(
        stage: .topLevelExpanded,
        tick: 0,
        lastDirection: nil
    )

    /// Per-id manual expansion overrides. Written by row `Button`
    /// taps via `toggleExpansion(_:)`; cleared on every non-no-op
    /// bulk action. Each entry encodes "this row is at a value DIFFERENT
    /// from what `bulkState.stage` would imply" — entries equal to the
    /// stage-default are removed automatically. From this invariant,
    /// `hasExpandFiddle` = any `true` entry (above default) and
    /// `hasCollapseFiddle` = any `false` entry (below default).
    /// Bulk action behavior:
    ///   - `Collapse` clicked while `hasExpandFiddle`: snap rows back
    ///     to current stage (close the user's expansions). Don't
    ///     advance — matches "first collapse undoes my fiddle, then
    ///     advance."
    ///   - `Expand` clicked while `hasCollapseFiddle`: symmetric.
    ///   - `Expand` clicked while `hasExpandFiddle` only: advance
    ///     toward `fullyExpanded` directly. The user fiddled in the
    ///     same direction as the click; they want MORE, not snap-back.
    @Published private(set) var expansionOverrides: ExpansionOverrides = ExpansionOverrides()

    /// Trigger a stepped collapse-all signal for row views. See
    /// `ExpansionOverrides.collapseOutcome(stage:overrides:)` for the
    /// pure-function semantics that this method drives — extracted so
    /// the bulk-action behavior is unit-testable without instantiating
    /// the panel.
    func collapseAll() {
        applyBulkOutcome(
            ExpansionOverrides.collapseOutcome(
                stage: bulkState.stage,
                overrides: expansionOverrides
            ),
            direction: .collapse
        )
    }

    /// Trigger a stepped expand-all signal for row views. Mirror of
    /// `collapseAll()`.
    func expandSnap() {
        applyBulkOutcome(
            ExpansionOverrides.expandOutcome(
                stage: bulkState.stage,
                overrides: expansionOverrides
            ),
            direction: .expand
        )
    }

    /// Apply a bulk-outcome decision to the panel's state. Both the
    /// `advance` and `snapBack` outcomes clear `expansionOverrides`
    /// and bump the tick; only `advance` changes the stage. `noop`
    /// publishes nothing so the view's `.onChange(of: panel.bulkState)`
    /// stays silent at terminal-stage clicks.
    private func applyBulkOutcome(
        _ outcome: BulkOutcome,
        direction: BulkExpansionState.Direction
    ) {
        let nextStage: BulkExpansionStage
        switch outcome {
        case .noop:
            return
        case .advance(let to):
            nextStage = to
        case .snapBack:
            nextStage = bulkState.stage
        }
        expansionOverrides.clear()
        bulkState = BulkExpansionState(
            stage: nextStage,
            tick: bulkState.tick &+ 1,
            lastDirection: direction
        )
    }

    /// Identifies the per-row knob the user toggled. The panel
    /// computes the resolved current value (from `expansionOverrides`
    /// + `bulkState.stage`) and writes the flipped value back to the
    /// override dict. Rows never compute the toggle direction.
    enum ExpansionToggle {
        case aiHeader(chunkId: String)
        case thinking(chunkId: String)
        case tool(toolId: String)
        case chunkBody(chunkId: String)
    }

    /// Apply a manual expansion toggle. Reads the current resolved
    /// value, flips it, writes to `expansionOverrides`. Entries equal
    /// to the bulk default are dropped so `hasExpandFiddle` /
    /// `hasCollapseFiddle` accurately reflect "the user is currently
    /// off-default in this direction" without sticky flags.
    func toggleExpansion(_ toggle: ExpansionToggle) {
        let key: String
        let defaultValue: Bool
        let stage = bulkState.stage
        switch toggle {
        case .aiHeader(let id):
            key = "ai:\(id)"
            defaultValue = stage != .fullyCollapsed
        case .thinking(let id):
            key = "thinking:\(id)"
            defaultValue = stage == .fullyExpanded
        case .tool(let id):
            key = "tool:\(id)"
            defaultValue = stage == .fullyExpanded
        case .chunkBody(let id):
            key = "chunk:\(id)"
            defaultValue = stage == .fullyExpanded
        }
        let current = expansionOverrides.value(forKey: key, default: defaultValue)
        expansionOverrides.set(key: key, value: !current, defaultValue: defaultValue)
    }

    enum BulkExpansionStage: String, Equatable {
        case fullyCollapsed
        case topLevelExpanded
        case fullyExpanded
    }

    /// Atomic snapshot of the panel's bulk-expansion intent. Equal
    /// when stage, tick, and direction all match — the tick guarantees
    /// that terminal-stage clicks (e.g., a second "Expand all" while
    /// already at `.fullyExpanded`) still publish a change so
    /// previously-fiddled rows snap back to the panel stage.
    ///
    /// `lastDirection` carries the click direction the panel view
    /// reads to decide whether to clamp scroll-to-bottom on bulk
    /// actions. `.collapse` shrinks content (or stays the same on
    /// snap-back, which can also shrink) — at-bottom users would
    /// otherwise see blank space below the now-shorter list.
    /// `.expand` grows content; no scroll clamp needed.
    struct BulkExpansionState: Equatable {
        let stage: BulkExpansionStage
        let tick: Int
        let lastDirection: Direction?

        enum Direction: Equatable {
            case collapse
            case expand
        }
    }

    /// Decision returned by `ExpansionOverrides.collapseOutcome` /
    /// `expandOutcome`. Lets the bulk-action semantics live as pure
    /// functions for testability while the panel handles the
    /// imperative side effects (clearing overrides, bumping tick,
    /// publishing).
    enum BulkOutcome: Equatable {
        case noop
        case advance(to: BulkExpansionStage)
        case snapBack
    }

    /// Per-id manual expansion overrides. Keyed by a string that
    /// includes a `kind:` prefix (`ai:`, `thinking:`, `tool:`,
    /// `chunk:`) so different knobs don't collide. Entries are
    /// **always different from the stage default** — `set(...)` drops
    /// the entry when the new value equals the default. This makes
    /// `hasExpandFiddle` / `hasCollapseFiddle` simple boolean walks
    /// of the dict, and removes the need for sticky flags that would
    /// have to reset on revert-toggles.
    struct ExpansionOverrides: Equatable {
        private(set) var values: [String: Bool] = [:]

        var isEmpty: Bool { values.isEmpty }

        /// True iff at least one row is more expanded than the bulk
        /// default — the user opened something they otherwise wouldn't
        /// see. Read by `collapseAll()` to decide snap-back vs advance.
        var hasExpandFiddle: Bool { values.contains { _, v in v } }

        /// True iff at least one row is less expanded than the bulk
        /// default — the user closed something the bulk would have
        /// kept open. Read by `expandSnap()`.
        var hasCollapseFiddle: Bool { values.contains { _, v in !v } }

        func value(forKey key: String, default defaultValue: Bool) -> Bool {
            values[key] ?? defaultValue
        }

        mutating func set(key: String, value: Bool, defaultValue: Bool) {
            if value == defaultValue {
                values.removeValue(forKey: key)
            } else {
                values[key] = value
            }
        }

        mutating func clear() {
            values.removeAll(keepingCapacity: false)
        }

        /// Pure computation of what `collapseAll()` should do given
        /// the panel's stage and current overrides. Behavior:
        /// - At `fullyCollapsed` with no expand-direction overrides:
        ///   `.noop`.
        /// - With `hasExpandFiddle`: `.snapBack` (close the user's
        ///   manual expansions; don't advance the stage).
        /// - Otherwise: `.advance(to:)` one stage downward.
        static func collapseOutcome(
            stage: BulkExpansionStage,
            overrides: ExpansionOverrides
        ) -> BulkOutcome {
            if stage == .fullyCollapsed && !overrides.hasExpandFiddle {
                return .noop
            }
            if overrides.hasExpandFiddle {
                return .snapBack
            }
            switch stage {
            case .fullyExpanded: return .advance(to: .topLevelExpanded)
            case .topLevelExpanded: return .advance(to: .fullyCollapsed)
            case .fullyCollapsed: return .noop
            }
        }

        /// Pure mirror of `collapseOutcome`. Snap-back triggers on
        /// `hasCollapseFiddle`; the no-op case is `fullyExpanded`
        /// without collapse-direction overrides.
        static func expandOutcome(
            stage: BulkExpansionStage,
            overrides: ExpansionOverrides
        ) -> BulkOutcome {
            if stage == .fullyExpanded && !overrides.hasCollapseFiddle {
                return .noop
            }
            if overrides.hasCollapseFiddle {
                return .snapBack
            }
            switch stage {
            case .fullyCollapsed: return .advance(to: .topLevelExpanded)
            case .topLevelExpanded: return .advance(to: .fullyExpanded)
            case .fullyExpanded: return .noop
            }
        }
    }

    /// Turn anchors keyed by user-chunk id. Populated by exact
    /// `claude_anchor` socket events for live prompts (when the
    /// inspector + cmux are both running) — never by approximation.
    let turnAnchorStore = TurnAnchorStore()

    /// User-chunk ids that currently have an anchor. View reads this
    /// to partition chunks for the `.preAnchored` filter case while
    /// preserving the snapshot-boundary policy (no direct access to
    /// the store from the view).
    var anchoredUserIds: Set<String> {
        Set(turnAnchorStore.orderedAnchors.map(\.userChunkId))
    }

    /// Single source of truth for "is the inspector currently locked
    /// onto a specific snap turn?". True iff snap mode is on AND the
    /// active filter is `.turns(...)` — i.e., the chunks rendered are
    /// the contents of a real conversation turn the user is anchored
    /// onto. False for `.off` (free scroll), `.all` (every chunk
    /// rendered), and `.preAnchored` (free-scroll history zone).
    ///
    /// All snap-turn-specific UX must gate on this predicate:
    /// status-bar pill visibility (auto-expand toggle, Expand-snap
    /// action) and the auto-expand-on-filter-change trigger.
    var isShowingSnapTurn: Bool {
        guard syncMode == .snap else { return false }
        if case .turns = visibleTurnFilter { return true }
        return false
    }

    /// Transcript stream — live `AgentChunk` snapshots. Empty in detail mode.
    let stream = TranscriptStream()

    private var focusedSurfaceObserver: FocusedSurfaceObserver?
    private var sessionCancellable: AnyCancellable?
    private var streamCancellable: AnyCancellable?
    private var scrollbarObserver: NSObjectProtocol?
    private var claudeAnchorObserver: NSObjectProtocol?
    /// FIFO queue of `claude_anchor` socket events that arrived
    /// before the corresponding user chunk landed in the stream.
    /// Drained by `drainPendingClaudeAnchors()` on each chunk update.
    private var pendingClaudeAnchors: [ClaudeAnchorPayload] = []
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

        // Phase C: restore persisted toggle values before any property
        // observers fire (first assignment in init bypasses didSet).
        if let raw = UserDefaults.standard.string(forKey: "agentInspector.rewindVisibility"),
           let v = InspectorRewindVisibility(rawValue: raw) {
            self.rewindVisibility = v
        }
        if let raw = UserDefaults.standard.string(forKey: "agentInspector.expansionMode"),
           let v = InspectorExpansionMode(rawValue: raw) {
            self.expansionMode = v
        }

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
        // this hook to drain any pending claude_anchor records, refresh
        // the visible-turn filter, and update the streaming-pulse state.
        streamCancellable = stream.objectWillChange
            .sink { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                // Anchor capture and downstream recomputes happen AFTER
                // the upstream change is applied; defer one tick so
                // `stream.chunks` reflects the new state.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.drainPendingClaudeAnchors()
                    self.pairAIChunksToTurnAnchors()
                    self.recomputeVisibleTurnFilter()
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

        // Subscribe to exact-anchor records emitted by the cmux app's
        // v1 `claude_anchor` socket handler. Posted whenever the
        // `prompt-submit` claude-hook fires for any session. We only
        // queue records whose `sessionId` matches the inspector's
        // resolved session; everything else is ignored.
        claudeAnchorObserver = NotificationCenter.default.addObserver(
            forName: .cmuxClaudePromptSubmitted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleClaudeAnchorNotification(note)
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
        // Drop pending anchor records for the previous session — they
        // can't apply to the new one.
        pendingClaudeAnchors.removeAll(keepingCapacity: true)
        // Recompute the visible-turn filter SYNCHRONOUSLY against the
        // new session's chunks. Without this, SwiftUI's first re-render
        // after the session swap uses the stale filter from the
        // previous session — typically `.turns([oldUserId])` whose id
        // does not exist in the new chunk set, producing an empty
        // `visibleChunks` and a brief "Waiting for transcript" flash
        // before `streamCancellable`'s deferred recompute lands on the
        // next runloop.
        recomputeVisibleTurnFilter()
        recomputeStreamingAIChunkId()
        objectWillChange.send()
    }

    /// Drain queued `claude_anchor` records by FIFO-pairing each one
    /// with the next unanchored user chunk that has appeared in the
    /// stream. Records are consumed only when their corresponding user
    /// chunk has actually landed; otherwise they remain queued.
    ///
    /// Pre-inspector / resumed user chunks (those that arrived in the
    /// stream before any `claude_anchor` was queued) get **no** anchor
    /// — the visible-turn filter routes them through the
    /// `.preAnchored` regime instead.
    private func drainPendingClaudeAnchors() {
        guard case .live = mode, !pendingClaudeAnchors.isEmpty else { return }
        let chunks = stream.chunks
        guard !chunks.isEmpty else { return }
        let result = pairClaudeAnchorsToUserChunks(
            chunks: chunks,
            queue: pendingClaudeAnchors,
            isAnchored: { [turnAnchorStore] id in
                turnAnchorStore.anchor(forChunkId: id) != nil
            }
        )
        for pairing in result.pairings {
            turnAnchorStore.recordTurnStart(
                userChunkId: pairing.userChunkId,
                terminalRow: pairing.payload.terminalRowAtSubmit,
                totalAtCapture: pairing.payload.totalAtCapture,
                at: pairing.payload.capturedAt
            )
        }
        pendingClaudeAnchors = result.remainingQueue
    }

    /// Walk the stream once to pair every recorded user-chunk anchor
    /// with its first following AI chunk. Idempotent.
    private func pairAIChunksToTurnAnchors() {
        guard case .live = mode else { return }
        let chunks = stream.chunks
        guard !chunks.isEmpty else { return }
        var lastUnpairedUserId: String? = {
            for anchor in turnAnchorStore.orderedAnchors.reversed() {
                if anchor.aiChunkId == nil { return anchor.userChunkId }
            }
            return nil
        }()
        for chunk in chunks {
            switch chunk {
            case .user(let user):
                if turnAnchorStore.anchor(forChunkId: user.id) != nil {
                    lastUnpairedUserId = user.id
                }
            case .ai(let ai):
                if let userId = lastUnpairedUserId {
                    turnAnchorStore.pairAIChunk(userChunkId: userId, aiChunkId: ai.id)
                    lastUnpairedUserId = nil
                }
            case .system, .compact, .meta:
                break
            }
        }
    }

    /// Handler for `Notification.Name.cmuxClaudePromptSubmitted`.
    /// Filters by the inspector's currently-resolved session and
    /// queues matching records for FIFO drain on the next stream
    /// update.
    private func handleClaudeAnchorNotification(_ note: Notification) {
        guard case .live = mode else { return }
        guard let payload = note.claudeAnchorPayload else { return }
        guard let resolved = resolvedSession,
              resolved.sessionId == payload.sessionId else {
            return
        }
        pendingClaudeAnchors.append(payload)
        // The user chunk for this prompt may already be in the stream
        // (rare: hook fires after JSONL flush + tail debounce). Try
        // draining immediately so the anchor is recorded without
        // waiting for the next stream tick.
        drainPendingClaudeAnchors()
        recomputeVisibleTurnFilter()
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
            self.recomputeVisibleTurnFilter()
        }
    }

    /// Compute the visible-turn filter from the cached scrollbar state
    /// of the paired terminal and publish it. Equality short-circuit
    /// on the enum keeps redundant scroll events within the same turn
    /// from invalidating the parent view body.
    func recomputeVisibleTurnFilter() {
        guard case .live = mode else { return }
        guard syncMode == .snap else {
            if visibleTurnFilter != .all { visibleTurnFilter = .all }
            return
        }
        guard let surfaceUUIDString = resolvedSession?.surfaceId,
              let surfaceUUID = UUID(uuidString: surfaceUUIDString) else {
            if visibleTurnFilter != .all { visibleTurnFilter = .all }
            return
        }
        let scrollbar = ScrollbarStateCache.shared.latest(for: surfaceUUID)
        let snapshot = scrollbar.map(VisibleTurnScrollSnapshot.init)
        let computed = computeVisibleTurnFilter(
            scrollbar: snapshot,
            chunks: stream.chunks,
            anchors: turnAnchorStore.orderedAnchors
        )
        if computed != visibleTurnFilter {
            visibleTurnFilter = computed
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
        if let claudeAnchorObserver {
            NotificationCenter.default.removeObserver(claudeAnchorObserver)
        }
        claudeAnchorObserver = nil
        pendingClaudeAnchors.removeAll(keepingCapacity: false)
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
             .systemOutput(let id),
             .assistantResponse(let id),
             .skillBody(let id),
             .slashCommandBody(let id),
             .systemReminderBody(let id),
             .recapBody(let id),
             .localCommandCaveatBody(let id):
            return id
        case .toolInput(let chunkId, _),
             .toolResult(let chunkId, _),
             .subagentTranscript(let chunkId, _):
            return chunkId
        case .abandonedBranch(let branchRootUuid):
            return branchRootUuid
        }
    }
}
