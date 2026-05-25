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
        let visibleChunks: [AgentChunk] = {
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
        let snapshots = visibleChunks.map {
            ChunkRowSnapshot.from($0, agentKind: agentKind)
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
                    guard isFollowingLiveTail(snapshots: snapshots) else { return }
                    scrollToBottom(proxy: proxy, snapshots: snapshots)
                }
            }
        }
    }

    /// True when the inspector is currently rendering the live tail —
    /// i.e. the last chunk in the displayed snapshot list is also the
    /// last user chunk (or last chunk overall) of the full stream. In
    /// this state, new chunks landing at the bottom should auto-scroll
    /// the inspector. Older anchored turns and pre-anchored free-scroll
    /// zones are not auto-scrolled.
    private func isFollowingLiveTail(snapshots: [ChunkRowSnapshot]) -> Bool {
        guard let displayedLastId = snapshots.last?.id else { return false }
        let allChunks = panel.stream.chunks
        guard let streamLastId = allChunks.last?.id else { return false }
        return displayedLastId == streamLastId
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

    /// Scroll the inspector to the bottom of the LazyVStack containing
    /// the chunk rows. Aligning the LazyVStack's own bottom edge with
    /// the viewport bottom lands at exactly the spot the user can
    /// reach by manual scroll inside the chunk list — including past
    /// the trailing Divider — without adding a sentinel view to the
    /// layout.
    ///
    /// Used by the live-tail follow path (`stream.lineCount` change):
    /// while the filter is rendering the latest turn at the bottom,
    /// new chunks landing should keep the user pinned at the tail.
    /// Filter transitions go through `scrollForFilter(...)` instead so
    /// the landing position depends on the filter regime.
    private func scrollToBottom(
        proxy: ScrollViewProxy,
        snapshots: [ChunkRowSnapshot]
    ) {
        guard !snapshots.isEmpty else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo(Self.chunkListId, anchor: .bottom)
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
