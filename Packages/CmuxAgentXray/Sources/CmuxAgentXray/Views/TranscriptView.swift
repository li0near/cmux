public import SwiftUI

/// Top-level live transcript view for an `AgentXrayPanel`. Layout:
///
///     ┌── status bar ────────────────────────────────────────────┐
///     │ ◐  attached <session>            scroll: snap   ↻ ⇲ ⇣⇡ ⇡⇣│
///     ├── divider (foreground@0.15) ─────────────────────────────┤
///     │ User      <prompt preview…>          [12 words]  HH:mm:ss│
///     │ Claude  Opus 4.6  [4.0M tokens]                  HH:mm:ss│
///     │   thinking · 1 lines                                     │
///     │   ↗ assistant response · 108 words                       │
///     │   Read /foo/bar.swift                            41 ms   │
///     │   ...                                                    │
///     └──────────────────────────────────────────────────────────┘
///
/// Per-entry chrome lives on the entry views themselves (no shared
/// modifier). Sub-entry indent: `Theme.Indent.unit` (22pt).
@available(macOS 15, *)
public struct TranscriptView: View {

    @Bindable public var panel: AgentXrayPanel
    public let appearance: HostAppearance

    /// Tracks which entry is currently at the viewport top, derived
    /// from per-entry anchor preferences via `EntryAnchorsKey`. Used
    /// by the bulk-expand materialize-kick to re-pin the viewport
    /// after content reflows.
    @State private var currentTopVisibleID: String?

    public init(panel: AgentXrayPanel, appearance: HostAppearance) {
        self.panel = panel
        self.appearance = appearance
    }

    public var body: some View {
        switch panel.mode {
        case .live:
            VStack(spacing: 0) {
                statusBar
                topDivider
                transcriptList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appearance.contentBackgroundColor)
        case .detail(let content):
            detailView(content: content)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        return StatusBarView(
            palette: palette,
            stage: AttachStage.derive(
                resolvedSession: panel.resolvedSession,
                entries: panel.stream.entries
            ),
            streamError: panel.stream.error,
            attachedTitle: resolvedSessionTitle,
            scrollMode: panel.scrollMode,
            rewindVisibility: panel.rewindVisibility,
            expansionMode: panel.expansionMode,
            canCollapse: panel.canCollapse,
            canExpand: panel.canExpand,
            onClearRemoteSession: clearRemoteSessionHandler,
            onToggleScrollMode: {
                panel.scrollMode = panel.scrollMode == .snap ? .free : .snap
            },
            onCycleRewindVisibility: {
                panel.rewindVisibility = panel.rewindVisibility.cycled()
            },
            onCycleExpansionMode: {
                panel.expansionMode = panel.expansionMode.cycled()
            },
            onCollapseAll: { panel.collapseAll() },
            onExpandAll: { panel.expandAll() }
        )
    }

    /// Non-nil only when the resolved session was attached via path 3
    /// (`.remote(_:)` transport). Tapping clears the persisted id —
    /// the panel detaches and `RemoteAttachPromptView` re-renders.
    private var clearRemoteSessionHandler: (() -> Void)? {
        guard let transport = panel.resolvedSession?.transport,
              case .remote = transport else { return nil }
        return { panel.setRemoteClaudeSessionID(nil) }
    }

    private var resolvedSessionTitle: String? {
        guard let session = panel.resolvedSession else { return nil }
        let prefix = String(session.sessionID.prefix(8))
        let cwd = session.cwd ?? ""
        return "attached \(session.agentKind.rawValue) \(prefix)…\(cwd)"
    }

    private var topDivider: some View {
        Divider()
            .background(appearance.foregroundColor.opacity(Theme.Opacity.divider))
    }

    // MARK: - Transcript list

    private var transcriptList: some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        let entries = visibleEntries()

        return Group {
            if entries.isEmpty {
                if panel.canShowRemoteAttachPrompt {
                    RemoteAttachPromptView(
                        panel: panel,
                        palette: palette,
                        destination: panel.remoteAttachDestination
                    )
                } else {
                    emptyTranscriptView(palette: palette)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Padding.entryGap) {
                            ForEach(entries, id: \.id.stableString) { entry in
                                entryView(for: entry, palette: palette)
                                    .background(alignment: .top) {
                                        // Zero-height scroll anchor for
                                        // turn-boundary navigation. Lives
                                        // OUTSIDE LazyVStack's child stream
                                        // so it doesn't consume an
                                        // `entryGap` worth of spacing.
                                        Color.clear
                                            .frame(height: 0)
                                            .id(dividerID(before: entry))
                                    }
                            }
                            // Tail anchor — single trailing zero-height view
                            // at the end of the list. No `entryGap` bug
                            // since there's no following sibling.
                            Color.clear
                                .frame(height: 0)
                                .id(tailBoundaryID(for: panel.entriesFilter))
                        }
                        .padding(.horizontal, Theme.Padding.transcriptOuter)
                        .padding(.vertical, Theme.Padding.transcriptOuter)
                        .id("cmux-agentxray-layout-\(panel.bulkState.layoutRevision)")
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.topLeading, for: .alignment)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .scrollIndicators(.never)
                    .backgroundPreferenceValue(EntryAnchorsKey.self) { anchors in
                        GeometryReader { geo in
                            Color.clear
                                .onChange(of: Set(anchors.keys)) { _, _ in
                                    // Filter to top-level entry IDs only — when
                                    // a rewind container is expanded, its
                                    // children publish anchors via the same
                                    // `entryView(for:)` dispatch, but those
                                    // ids are not valid `proxy.scrollTo`
                                    // targets at the parent LazyVStack and
                                    // would corrupt `currentTopVisibleID`.
                                    let topLevelIDs = Set(entries.map { $0.id.stableString })
                                    let filtered = anchors.filter { topLevelIDs.contains($0.key) }
                                    handleEntryAnchorsChange(anchors: filtered, geo: geo)
                                }
                        }
                    }
                    .onChange(of: panel.entriesFilter) { _, _ in
                        guard panel.scrollMode == .snap else { return }
                        scrollForFilter(proxy: proxy)
                    }
                    .onChange(of: panel.resolvedSession?.sessionID) { _, _ in
                        scrollForFilter(proxy: proxy)
                    }
                    .onChange(of: panel.bulkState) { _, newState in
                        switch newState.lastDirection {
                        case .collapse:
                            // Yield one runloop tick so the LazyVStack
                            // has a chance to remount under the new
                            // `layoutRevision` id before we re-route
                            // scroll position.
                            Task { @MainActor in
                                scrollForFilter(proxy: proxy)
                            }
                        case .expand:
                            if let topID = currentTopVisibleID {
                                Task { @MainActor in
                                    var tx = Transaction()
                                    tx.disablesAnimations = true
                                    withTransaction(tx) {
                                        proxy.scrollTo(topID, anchor: .top)
                                    }
                                }
                            }
                        case .none:
                            break
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Top-level entry dispatcher. Every entry — agent, synthesized
    /// rewind, prLink, user, system, compact — routes through the
    /// unified recursive ``EntryView`` at depth 0. Per-Entry-kind
    /// specifics (accent, emphasis, pulse, magenta chip) live inside
    /// the view via ``Entry/isEmphasized``,
    /// ``PaletteRole/forEntry(_:)``, and the ``Entry/expansionShape``
    /// dispatch.
    @ViewBuilder
    private func entryView(for entry: Entry, palette: HudPalette) -> some View {
        let entryID = entry.id.stableString
        EntryView(
            entry: entry,
            depth: 0,
            palette: palette,
            isExpanded: panel.currentExpanded.contains(entryID),
            isStreaming: panel.streamingEntryID == entryID,
            computed: panel.computedCache.compute(for: entry),
            actions: makeLiveActions()
        )
        .equatable()
        .transformAnchorPreference(
            key: EntryAnchorsKey.self,
            value: .bounds
        ) { dict, anchor in
            dict[entryID] = anchor
        }
    }

    /// Live-transcript ``EntryActions``. `isExpanded` reads the panel's
    /// shared expanded set so child Entries (sub-entries / abandoned
    /// branch tail) inherit the same wiring.
    private func makeLiveActions() -> EntryActions {
        EntryActions(
            isExpanded: { panel.currentExpanded.contains($0) },
            onToggleExpansion: { panel.toggleExpansion($0) },
            onOpenDetail: { panel.openDetail(request: $0) },
            computed: { panel.computedCache.compute(for: $0) }
        )
    }

    /// Default detail-tab routing for entries whose body has a single
    /// section the renderer treats as the canonical "open detail"
    /// surface. The unified ``EntryView`` body path calls
    /// ``EntryActions/onOpenDetail`` with a pre-wrapped per-section
    /// request, so this helper is no longer consulted at render time —
    /// retained for any future external callers that want a default
    /// open-target lookup.
    private func defaultDetailRequest(for entry: Entry) -> DetailRequest? {
        let id = entry.id.stableString
        switch entry {
        case .user, .system, .compact:
            return .bodySection(targetID: id, sectionIndex: 0)
        case .synthesized(let s):
            switch s.kind {
            case .rewind, .prLink:
                return nil
            }
        case .agent, .text, .tool:
            return nil
        }
    }

    /// Pick the divider id placed BEFORE `entry`. User entries get
    /// the `beforeTurnBoundaryID` (the canonical turn-boundary scroll
    /// target); other entries get a derived `before:<entry-id>`
    /// marker so `proxy.scrollTo(...)` can still target the slot
    /// even though it's not a turn boundary.
    private func dividerID(before entry: Entry) -> String {
        if case .user(let u) = entry {
            return beforeTurnBoundaryID(u.id.stableString)
        }
        return "__cmux_agentxray_before_entry__:\(entry.id.stableString)"
    }

    private func visibleEntries() -> [Entry] {
        let all = panel.stream.entries
        let postFilter: [Entry]
        switch panel.scrollMode {
        case .free:
            postFilter = all
        case .snap:
            postFilter = entriesForFilter(
                entries: all,
                filter: panel.entriesFilter,
                anchoredUserIDs: panel.anchoredUserEntryIDs
            )
        }
        if panel.rewindVisibility == .hide {
            return postFilter.filter { entry in
                if case .synthesized(let s) = entry,
                   case .rewind = s.kind { return false }
                return true
            }
        }
        return postFilter
    }

    // MARK: - Scroll routing

    /// Cross-band routing on filter / session-change / bulk-collapse.
    /// Picks a scroll target — a turn-boundary id or the tail-boundary
    /// id — and scrolls to it without animation.
    private func scrollForFilter(proxy: ScrollViewProxy) {
        let entries = panel.stream.entries
        guard !entries.isEmpty else { return }
        let target = scrollTarget(
            entries: entries,
            filter: panel.entriesFilter,
            anchoredUserIDs: panel.anchoredUserEntryIDs
        )
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    // MARK: - Anchor aggregation

    /// Resolve per-entry anchor frames against the scroll-view's
    /// geometry, find the entry currently at the viewport top, and
    /// publish it as `currentTopVisibleID`.
    private func handleEntryAnchorsChange(
        anchors: [String: Anchor<CGRect>],
        geo: GeometryProxy
    ) {
        var resolved: [(id: String, rect: CGRect)] = []
        resolved.reserveCapacity(anchors.count)
        for (id, anchor) in anchors {
            resolved.append((id: id, rect: geo[anchor]))
        }
        resolved.sort { $0.rect.minY < $1.rect.minY }
        let topVisible = resolved.first(where: { $0.rect.minY >= 0 }) ?? resolved.first
        let topVisibleID = topVisible?.id
        if currentTopVisibleID != topVisibleID {
            currentTopVisibleID = topVisibleID
        }
    }

    // MARK: - Empty / detail

    private func emptyTranscriptView(palette: HudPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyHeader)
                .font(Theme.Entry.nameEmphasis)
                .foregroundStyle(palette.primary)
            Text(emptyDetail)
                .font(Theme.Entry.title)
                .foregroundStyle(palette.dim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyHeader: String {
        if panel.resolvedSession != nil {
            return String(
                localized: "agentXray.empty.attached.header",
                defaultValue: "Waiting for transcript",
                bundle: .module
            )
        }
        return String(
            localized: "agentXray.placeholder.header",
            defaultValue: "Agent X-ray",
            bundle: .module
        )
    }

    private var emptyDetail: String {
        if panel.resolvedSession != nil {
            return String(
                localized: "agentXray.empty.attached.detail",
                defaultValue: "Hooked. Run a prompt to see entries here.",
                bundle: .module
            )
        }
        return String(
            localized: "agentXray.placeholder.noSession",
            defaultValue: "No session yet. Focus a terminal running claude or codex — Agent X-ray follows the focused terminal automatically.",
            bundle: .module
        )
    }

    // MARK: - Detail view (frozen)

    /// Detail-mode rendering. Every non-transcript detail click
    /// redirects through cmux's panel-open pipeline before reaching
    /// the package's `.detail` mode at all (see
    /// `AgentXrayWorkspaceHost.openDetailTab` routing). This view is
    /// therefore reachable only for `.transcript` content
    /// (sub-agent / abandoned-branch transcripts) — structured Entry
    /// arrays that don't fit cmux's file-driven panel system.
    /// Anything else hitting `.detail` mode is a defensive fallback
    /// path that surfaces a localized "opened externally" placeholder.
    private func detailView(content: DetailContent) -> some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        let accent = palette.color(for: content.accent)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.Spacing.entryIconText) {
                Image(systemName: content.icon.collapsed)
                    .font(Theme.DetailPanel.heading)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(Theme.DetailPanel.heading)
                        .foregroundStyle(palette.primary)
                    if let subtitle = content.subtitle {
                        Text(subtitle)
                            .font(Theme.DetailPanel.subtitle)
                            .foregroundStyle(palette.dim)
                    }
                }
                Spacer(minLength: 0)
            }
            if case .transcript(_, let entries) = content.source, !entries.isEmpty {
                detailEntriesList(entries: entries, palette: palette)
            } else {
                Text(
                    String(
                        localized: "agentXray.detail.openedExternally",
                        defaultValue: "This content opened in a separate panel.",
                        bundle: .module
                    )
                )
                .font(Theme.DetailPanel.body)
                .foregroundStyle(palette.dim)
                .padding(Theme.Padding.expandedBodyBlock)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.contentBackgroundColor)
    }

    /// Render an entries array (abandoned-branch / sub-agent
    /// transcript) inline using the same EntryView dispatcher used
    /// for live transcripts. Detail mode shows everything expanded;
    /// the open-detail link is a no-op (no nested detail tabs).
    private func detailEntriesList(entries: [Entry], palette: HudPalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Padding.entryGap) {
                ForEach(entries, id: \.id.stableString) { entry in
                    detailEntryView(entry: entry, palette: palette)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }

    private func detailEntryView(entry: Entry, palette: HudPalette) -> some View {
        let entryID = entry.id.stableString
        return EntryView(
            entry: entry,
            depth: 0,
            palette: palette,
            isExpanded: true,
            isStreaming: false,
            computed: panel.computedCache.compute(for: entry),
            actions: detailActions()
        )
        .equatable()
        .id(entryID)
    }

    /// Detail-tab ``EntryActions``. `isExpanded` returns true
    /// unconditionally so abandoned-branch sub-entries materialize
    /// expanded — they're not in the panel's `currentExpanded` set
    /// (their ids were never observed by `autoExpandNewEntries`), and
    /// the detail tab shows the full structure inline. `onOpenDetail`
    /// is a no-op (no nested detail tabs).
    private func detailActions() -> EntryActions {
        EntryActions(
            isExpanded: { _ in true },
            onToggleExpansion: { _ in },
            onOpenDetail: { _ in },
            computed: { panel.computedCache.compute(for: $0) }
        )
    }
}

// MARK: - Anchor preference key

/// Per-entry `Anchor<CGRect>` aggregation key. Each entry view emits
/// its bounds via `transformAnchorPreference`; the parent
/// `backgroundPreferenceValue(EntryAnchorsKey.self)` resolves them
/// against the `GeometryProxy` to find the entry currently at the
/// viewport top — used as the materialize-kick re-pin target after
/// bulk-expand reflows the LazyVStack.
@available(macOS 15, *)
private struct EntryAnchorsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}
