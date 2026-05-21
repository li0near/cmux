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

    /// Three-state mode pill for sync behaviour. Cycles through
    /// off → tail → sync → off on each click. Visually compact so it fits
    /// the existing status bar.
    private var syncModePill: some View {
        Button(action: { panel.syncMode = nextSyncMode(after: panel.syncMode) }) {
            HStack(spacing: 4) {
                Text("scroll:")
                    .foregroundColor(Color(nsColor: appearance.foregroundColor).opacity(0.55))
                Text(panel.syncMode.label.lowercased())
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
        case .followTail: return palette.cyan
        case .syncToTerminal: return palette.green
        }
    }

    private func nextSyncMode(after mode: InspectorSyncMode) -> InspectorSyncMode {
        switch mode {
        case .off: return .followTail
        case .followTail: return .syncToTerminal
        case .syncToTerminal: return .off
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
        let snapshots = panel.stream.chunks.map {
            ChunkRowSnapshot.from($0, agentKind: agentKind)
        }
        let palette = HudPaletteToken.from(HudPalette(appearance: appearance))

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
                .onChange(of: snapshots.count) { _ in
                    // Tail-follow only fires when new content arrives at the
                    // bottom in `.followTail` mode. `.syncToTerminal` and
                    // `.off` ignore append events.
                    guard panel.syncMode == .followTail, let last = snapshots.last else { return }
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: panel.pendingScrollTarget) { newTarget in
                    // Bridge-issued programmatic scroll. Token-bearing so
                    // repeated requests for the same chunk id still apply.
                    //
                    // **No animation.** SwiftUI's implicit scroll
                    // animation queues at the view's animation rate, and
                    // at 120Hz the queue overflows producing the lag the
                    // user reported. VS Code, Beyond Compare, and
                    // AppKit's SynchroScrollView all set scroll position
                    // synchronously — the visible feedback IS the user's
                    // own scroll on the source pane. See
                    // `Transaction.disablesAnimations` in
                    // https://developer.apple.com/documentation/swiftui/transaction.
                    guard let target = newTarget else { return }
                    let unitPoint: UnitPoint = {
                        switch target.anchorPoint {
                        case .top: return .top
                        case .bottom: return .bottom
                        }
                    }()
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        proxy.scrollTo(target.chunkId, anchor: unitPoint)
                    }
                    panel.consumePendingScrollTarget()
                }
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
