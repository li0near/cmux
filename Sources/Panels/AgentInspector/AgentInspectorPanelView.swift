import SwiftUI
import AppKit

/// Live transcript view for the Agent Inspector panel. Reads chunks from the
/// panel's `TranscriptStream` and renders them as a terminal-styled list of
/// rows. Snapshot-boundary policy is enforced strictly:
///
/// - The `LazyVStack` of `ChunkRowView` rows below `transcriptList` receives
///   only immutable `ChunkRowSnapshot` values + a `HudPaletteToken`.
/// - The row view itself does not import or hold any reference to
///   `AgentInspectorPanel` / `TranscriptStream` / `Workspace`.
/// - All transformations (chunk → snapshot) happen on the main actor here,
///   in a `let` projection — never inside any view's `body` (CLAUDE.md
///   "No state mutation inside view-body computations.").
struct AgentInspectorPanelView: View {
    @ObservedObject var panel: AgentInspectorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    /// Stable id of the LazyVStack containing the chunk rows.
    /// Targeting this from `ScrollViewProxy.scrollTo(_:anchor:)` with
    /// anchor `.bottom` aligns the LazyVStack's own bottom edge with
    /// the viewport bottom — equivalent to the furthest the user can
    /// scroll manually inside the LazyVStack, with no sentinel view
    /// added to the layout.
    private static let chunkListId = "__cmux_inspector_chunk_list__"

    var body: some View {
        switch panel.mode {
        case .live:
            VStack(spacing: 0) {
                InspectorStatusBar(panel: panel, appearance: appearance)
                Divider()
                    .background(Color(nsColor: appearance.foregroundColor).opacity(0.15))
                transcriptList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.contentBackgroundColor))
            .id(panel.id)
        case .detail(let content):
            AgentInspectorDetailView(content: content, appearance: appearance)
                .id(panel.id)
        }
    }

    // MARK: - Transcript list

    // MARK: - Transcript list

    @ViewBuilder
    private var transcriptList: some View {
        let agentKind: ChunkRowSnapshot.AgentKindLabel = {
            switch panel.resolvedSession?.agentKind {
            case .claude: return .claude
            case .codex: return .codex
            case .none: return .unknown
            }
        }()
        let allChunks = panel.stream.chunks
        let postFilterChunks: [AgentChunk] = {
            switch panel.syncMode {
            case .off:
                return allChunks
            case .snap:
                return chunksForFilter(
                    chunks: allChunks,
                    filter: panel.visibleTurnFilter,
                    anchoredUserIds: panel.anchoredUserIds
                )
            }
        }()
        // Phase D.1: drop BranchLink rows when the user has hidden them.
        let visibleChunks: [AgentChunk] = panel.rewindVisibility == .hide
            ? postFilterChunks.filter {
                if case .meta(.branchLink) = $0 { return false }
                return true
            }
            : postFilterChunks
        // Resolve per-row expansion state from the panel's bulk stage
        // and per-id overrides. Baked into each `ChunkRowSnapshot` so
        // rows hold no `@State` for bulk-managed expansion — bulk
        // changes settle in one synchronous body pass for every row,
        // visible or off-screen, with no `.onChange` cascade.
        let stage = panel.bulkState.stage
        let overrides = panel.expansionOverrides
        let expansion = ChunkRowSnapshot.ExpansionResolver(
            chunkBodyOpen: { id in
                overrides.value(forKey: "chunk:\(id)", default: stage == .fullyExpanded)
            },
            aiHeaderOpen: { id in
                overrides.value(forKey: "ai:\(id)", default: stage != .fullyCollapsed)
            },
            thinkingOpen: { id in
                overrides.value(forKey: "thinking:\(id)", default: stage == .fullyExpanded)
            },
            toolExpanded: { id in
                overrides.value(forKey: "tool:\(id)", default: stage == .fullyExpanded)
            }
        )
        let snapshots = visibleChunks.map { chunk in
            let computed = panel.computedCache.compute(for: chunk, displayMode: .compact)
            return ChunkRowSnapshot.from(
                chunk,
                agentKind: agentKind,
                expansion: expansion,
                computed: computed
            )
        }
        let palette = HudPaletteToken.from(HudPalette(appearance: appearance))
        let streamingAIChunkId = panel.streamingAIChunkId

        if snapshots.isEmpty {
            emptyTranscriptView
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshots) { snapshot in
                            ChunkRowView(
                                snapshot: snapshot,
                                palette: palette,
                                streamingAIChunkId: streamingAIChunkId,
                                onOpenDetail: { request in
                                    panel.openDetail(request: request)
                                },
                                onToggleExpansion: { toggle in
                                    panel.toggleExpansion(toggle)
                                }
                            )
                            .equatable()
                            .id(snapshot.id)
                            Divider()
                                .background(Color(nsColor: appearance.foregroundColor).opacity(0.06))
                        }
                    }
                    .id(Self.chunkListId)
                    .padding(.vertical, 6)
                }
                // Match Ghostty's terminal scroller style: never show
                // the macOS legacy scrollbar (which would always be
                // visible and re-size as the LazyVStack estimates new
                // content heights). User scrolls via wheel / trackpad
                // — same model as the terminal pane.
                .scrollIndicators(.never)
                // On filter transitions and session change, route scroll
                // through `scrollForFilter` so the landing position
                // reflects the *intent* of each filter regime:
                //
                //   - `.turns([latestId])` (at-bottom snap) — bottom of
                //     the rendered chunk set (latest turn at bottom).
                //   - `.turns([olderTurnId])` — bottom of that turn.
                //   - `.preAnchored` (unanchored latest, expand to
                //     history) — the chunk just before the latest user
                //     prompt, anchored to the viewport bottom. Lands on
                //     pre-last-turn content; the latest turn is
                //     scrollable down, older history scrollable up.
                //
                // For live-tail line landings (`stream.lineCount`),
                // always scroll to the LazyVStack bottom — that's the
                // log-tail follow behavior.
                .onAppear {
                    scrollForFilter(proxy: proxy)
                }
                .onChange(of: panel.visibleTurnFilter) { _ in
                    scrollForFilter(proxy: proxy)
                    // Auto-expand fires only when the inspector has
                    // actually settled on a snap turn — `.preAnchored`
                    // history scrolling and `.all` free-scroll never
                    // open chunks automatically.
                    if panel.expansionMode == .autoExpandSnap, panel.isShowingSnapTurn {
                        panel.expandSnap()
                    }
                }
                // After a bulk collapse, content height shrinks and the
                // user's absolute scroll offset can land past the new
                // bottom → blank space. Rows render synchronously in
                // the same body pass as the panel (per-row `@State` is
                // gone; expansion is baked into the snapshot), so a
                // single `DispatchQueue.main.async` is enough to push
                // the scroll past the layout pass that publishes
                // shrunken row heights.
                .onChange(of: panel.bulkState) { newState in
                    guard newState.lastDirection == .collapse else { return }
                    DispatchQueue.main.async {
                        scrollToBottom(proxy: proxy)
                    }
                }
                // Belt-and-suspenders for tab-switch: even if the
                // ScrollView's session-keyed identity didn't flip
                // (rare race), an explicit handler on session change
                // forces the bottom snap.
                .onChange(of: panel.resolvedSession?.sessionId) { _ in
                    scrollForFilter(proxy: proxy)
                }
                // Log-tail behavior: when a new JSONL line lands AND
                // the filter is currently rendering the live tail,
                // auto-scroll the inspector to its own bottom so the
                // user keeps seeing new content. We track
                // `stream.lineCount` (not `snapshots.last?.id`)
                // because tool results, thinking continuations, and
                // assistant-text deltas are folded into the existing
                // trailing AI chunk — its `id` stays the same, but
                // the content grows. `lineCount` increments on every
                // ingested line regardless of folding, so it catches
                // tool calls landing inside the same turn. Other
                // filter states (older anchored turns, free-scroll
                // pre-anchored history) are not auto-scrolled —
                // the user is browsing those deliberately.
                .onChange(of: panel.stream.lineCount) { _ in
                    // Skip auto-scroll while reading history in
                    // `.preAnchored` — the user is intentionally
                    // browsing pre-anchor turns and shouldn't be
                    // jumped to the latest by an unrelated stream
                    // tick.
                    if case .preAnchored = panel.visibleTurnFilter { return }
                    guard isFollowingLiveTail() else { return }
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    /// True when the inspector is currently rendering the live tail —
    /// i.e. the last chunk in the displayed snapshot list is also the
    /// last chunk of the full stream. Reads `panel.stream.chunks` AND
    /// the filtered visible chunks live to avoid closure-staleness on
    /// rapid stream updates (the captured `snapshots` argument from
    /// the body could be one tick behind by the time `.onChange` of
    /// `stream.lineCount` fires).
    private func isFollowingLiveTail() -> Bool {
        guard let streamLastId = panel.stream.chunks.last?.id else { return false }
        guard let visibleLastId = visibleLastSnapshotId() else { return false }
        return visibleLastId == streamLastId
    }

    /// Id of the last visible chunk (post-filter, post-rewind-hide),
    /// re-derived live from `panel` state. Same projection as the
    /// `body`'s `visibleChunks` `let`, but readable from inside
    /// `.onChange` closures without paying the closure-staleness cost
    /// of capturing the body projection (per `DECISIONS.md`
    /// "Hard-won lessons → Closure-staleness in `.onChange` handlers").
    private func visibleLastSnapshotId() -> String? {
        let allChunks = panel.stream.chunks
        guard !allChunks.isEmpty else { return nil }
        let postFilter: [AgentChunk]
        switch panel.syncMode {
        case .off:
            postFilter = allChunks
        case .snap:
            postFilter = chunksForFilter(
                chunks: allChunks,
                filter: panel.visibleTurnFilter,
                anchoredUserIds: panel.anchoredUserIds
            )
        }
        let visible: [AgentChunk] = panel.rewindVisibility == .hide
            ? postFilter.filter {
                if case .meta(.branchLink) = $0 { return false }
                return true
            }
            : postFilter
        return visible.last?.id
    }

    /// Scroll the inspector based on the current filter regime. The
    /// target chunk-id is computed by `inspectorScrollTarget(...)`:
    /// `.turns(_)` lands at the LazyVStack's container bottom; the
    /// unanchored `.preAnchored` case lands on the chunk preceding
    /// the latest user prompt so the user sees pre-last-turn content
    /// at the bottom of the inspector instead of the same latest-turn
    /// chunks they were just at-bottom on.
    ///
    /// Reads `panel.stream.chunks`, `panel.visibleTurnFilter`, and
    /// `panel.anchoredUserIds` directly inside the closure to avoid
    /// closure-staleness on captured snapshots.
    private func scrollForFilter(proxy: ScrollViewProxy) {
        let chunks = panel.stream.chunks
        guard !chunks.isEmpty else { return }
        let target = inspectorScrollTarget(
            chunks: chunks,
            filter: panel.visibleTurnFilter,
            anchoredUserIds: panel.anchoredUserIds,
            chunkListId: Self.chunkListId
        )
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// Scroll the inspector to the last visible chunk's bottom edge.
    ///
    /// We target the last visible chunk's `id` (re-derived live to
    /// avoid closure-staleness) with `anchor: .bottom`, rather than
    /// the LazyVStack's container `.id(...)`. Targeting the container
    /// makes SwiftUI compute "where is the LazyVStack's bottom?" from
    /// the LazyVStack's total `contentSize`, which Apple documents
    /// as trading layout correctness for performance —
    /// "the system only calculates the geometry for subviews as they
    /// become visible" (`developer.apple.com/documentation/swiftui/
    /// creating-performant-scrollable-stacks`). Off-screen rows'
    /// estimated heights lag after a state change shrinks the
    /// visible rows, so the container's reported bottom is a stale
    /// pixel offset and the scroll lands past the real content end
    /// (blank-screen-on-collapse). Targeting the last row by id
    /// asks SwiftUI to position THAT specific row at the viewport
    /// bottom, which empirically tests whether `ScrollViewReader`
    /// resolves the target's frame from real layout or from the
    /// same estimated layout.
    ///
    /// Used by the live-tail follow path (`stream.lineCount` change)
    /// and by the bulk-collapse handler. Filter transitions go
    /// through `scrollForFilter(...)` instead so the landing position
    /// depends on the filter regime.
    ///
    /// Falls back to the LazyVStack container id if there are no
    /// visible chunks (defensive — the bulk-collapse handler is
    /// only reached when `snapshots` is non-empty).
    private func scrollToBottom(proxy: ScrollViewProxy) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            if let lastId = visibleLastSnapshotId() {
                proxy.scrollTo(lastId, anchor: .bottom)
            } else {
                proxy.scrollTo(Self.chunkListId, anchor: .bottom)
            }
        }
    }

    private var emptyTranscriptView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyHeader)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(nsColor: appearance.foregroundColor))
            Text(emptyDetail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: appearance.foregroundColor).opacity(0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyHeader: String {
        if panel.resolvedSession != nil {
            return String(
                localized: "agentInspector.empty.attached.header",
                defaultValue: "Waiting for transcript"
            )
        }
        return String(
            localized: "agentInspector.placeholder.header",
            defaultValue: "Agent Inspector"
        )
    }

    private var emptyDetail: String {
        if panel.resolvedSession != nil {
            return String(
                localized: "agentInspector.empty.attached.detail",
                defaultValue: "Hooked. Run a prompt to see chunks here."
            )
        }
        return String(
            localized: "agentInspector.placeholder.noSession",
            defaultValue: "No session yet. Focus a terminal running claude or codex — the inspector follows the focused terminal automatically."
        )
    }
}
