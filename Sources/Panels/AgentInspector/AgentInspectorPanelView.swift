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

    var body: some View {
        switch panel.mode {
        case .live:
            VStack(spacing: 0) {
                statusBar
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

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(statusGlyph)
                .foregroundColor(statusGlyphColor)
            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: appearance.foregroundColor))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            syncModePill
            Text("\(panel.stream.lineCount) lines")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: appearance.foregroundColor).opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Two-state mode pill. `free` = render the entire transcript;
    /// `snap` = filter to chunks belonging to the turn(s) currently
    /// visible in the paired terminal viewport (with implicit live tail
    /// at the bottom).
    private var syncModePill: some View {
        Button(action: { panel.syncMode = nextSyncMode(after: panel.syncMode) }) {
            HStack(spacing: 4) {
                Text("scroll:")
                    .foregroundColor(Color(nsColor: appearance.foregroundColor).opacity(0.55))
                Text(panel.syncMode.label)
                    .foregroundColor(syncModeAccent)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(syncModeAccent.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var syncModeAccent: Color {
        let palette = HudPalette(appearance: appearance)
        switch panel.syncMode {
        case .off: return palette.dim
        case .snap: return palette.green
        }
    }

    private func nextSyncMode(after mode: InspectorSyncMode) -> InspectorSyncMode {
        switch mode {
        case .off: return .snap
        case .snap: return .off
        }
    }

    private var statusGlyph: String {
        panel.resolvedSession == nil ? HudGlyph.activeDot : HudGlyph.runningCircle
    }

    private var statusGlyphColor: Color {
        let palette = HudPalette(appearance: appearance)
        return panel.resolvedSession == nil ? palette.dim : palette.yellow
    }

    private var statusText: String {
        if let session = panel.resolvedSession {
            let prefix = String(session.sessionId.prefix(8))
            return String(
                localized: "agentInspector.status.attached",
                defaultValue: "attached \(session.agentKind.rawValue) \(prefix) — \(session.cwd ?? "")"
            )
        }
        return String(
            localized: "agentInspector.status.detached",
            defaultValue: "no agent attached — focus a terminal running claude"
        )
    }

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
                    .padding(.vertical, 6)
                }
                // Match Ghostty's terminal scroller style: never show
                // the macOS legacy scrollbar (which would always be
                // visible and re-size as the LazyVStack estimates new
                // content heights). User scrolls via wheel / trackpad
                // — same model as the terminal pane.
                .scrollIndicators(.never)
                // On ANY filter transition, scroll to the bottom of
                // the displayed chunk list. Preserving the previous
                // scroll position across filter changes is hard
                // (LazyVStack content shape changes when the chunk
                // list changes), and the user explicitly prefers
                // landing at the bottom over landing at the top:
                //
                //   - `.turns(latestTurnId)` — log-tail follow.
                //   - `.turns(olderTurnId)` — bottom of that turn's
                //     chunks (user just navigated there; show the
                //     most recent content of the turn).
                //   - `.preAnchored` — bottom of the unanchored
                //     history (mirrors Claude's resume positioning).
                .onAppear {
                    scrollToBottom(proxy: proxy, snapshots: snapshots)
                }
                .onChange(of: panel.visibleTurnFilter) { _ in
                    scrollToBottom(proxy: proxy, snapshots: snapshots)
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
                    guard isFollowingLiveTail(snapshots: snapshots),
                          let lastId = snapshots.last?.id else { return }
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
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

    /// Scroll the inspector to the bottom of the currently displayed
    /// chunk list. Animations disabled to avoid the SwiftUI
    /// animation-queue overflow that bit Phase B v1 — this is a
    /// one-shot snap, not a continuous follow.
    private func scrollToBottom(
        proxy: ScrollViewProxy,
        snapshots: [ChunkRowSnapshot]
    ) {
        guard let lastId = snapshots.last?.id else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo(lastId, anchor: .bottom)
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
