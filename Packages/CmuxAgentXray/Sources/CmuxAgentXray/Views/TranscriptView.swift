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
/// modifier). Sub-entry indent: `Theme.Indent.subRow` (22pt).
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
            .background(Color(nsColor: appearance.contentBackgroundColor))
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

    private var resolvedSessionTitle: String? {
        guard let session = panel.resolvedSession else { return nil }
        let prefix = String(session.sessionID.prefix(8))
        let cwd = session.cwd ?? ""
        return "attached \(session.agentKind.rawValue) \(prefix)…\(cwd)"
    }

    private var topDivider: some View {
        Divider()
            .background(Color(nsColor: appearance.foregroundColor).opacity(Theme.Opacity.divider))
    }

    // MARK: - Transcript list

    private var transcriptList: some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        let entries = visibleEntries()

        return Group {
            if entries.isEmpty {
                emptyTranscriptView(palette: palette)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id.stableString) { index, entry in
                                if index > 0 {
                                    boundaryDivider(id: dividerID(before: entry), palette: palette)
                                }
                                entryRow(for: entry, palette: palette)
                            }
                            boundaryDivider(id: tailBoundaryID(for: panel.entriesFilter), palette: palette)
                        }
                        .padding(.vertical, 6)
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
                                    handleEntryAnchorsChange(anchors: anchors, geo: geo)
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

    /// Top-level entry dispatcher. AgentEntry takes the specialized
    /// per-kind path; synthesized branch-link entries take a compact
    /// sub-row style; everything else routes through the generic
    /// `EntryView`. Both paths attach an anchor preference for
    /// viewport-top tracking.
    @ViewBuilder
    private func entryRow(for entry: Entry, palette: HudPalette) -> some View {
        let entryID = entry.id.stableString
        Group {
            switch entry {
            case .agent(let agent):
                AgentEntryView(
                    entry: agent,
                    palette: palette,
                    isExpanded: panel.currentExpanded.contains(entryID),
                    isStreaming: panel.streamingEntryID == entryID,
                    isSubEntryExpanded: { panel.currentExpanded.contains($0) },
                    onToggleExpansion: { panel.toggleExpansion($0) },
                    onOpenDetail: { panel.openDetail(request: $0) }
                )
            case .synthesized(let syn):
                synthesizedEntryRow(entry: syn, palette: palette)
            default:
                genericEntryView(entry: entry, palette: palette)
            }
        }
        .transformAnchorPreference(
            key: EntryAnchorsKey.self,
            value: .bounds
        ) { dict, anchor in
            dict[entryID] = anchor
        }
    }

    /// Per-kind dispatch for `SynthesizedEntry`. Branch links render as
    /// a compact sub-row (predecessor parity, PARITY §3.15 / §5b);
    /// PR links render via the generic `EntryView` since they're a
    /// header-only external link.
    @ViewBuilder
    private func synthesizedEntryRow(entry: SynthesizedEntry, palette: HudPalette) -> some View {
        switch entry.kind {
        case .branchLink(let rootUUID, let rewindIndex, let totalRewinds, let entryCount, let firstPromptPreview):
            BranchLinkEntryRow(
                rewindIndex: rewindIndex,
                totalRewinds: totalRewinds,
                entryCount: entryCount,
                firstPromptPreview: firstPromptPreview,
                palette: palette,
                onOpenDetail: {
                    panel.openDetail(request: .abandonedBranch(branchRootUuid: rootUUID))
                }
            )
            .id(entry.id.stableString)
        case .prLink:
            genericEntryView(entry: .synthesized(entry), palette: palette)
        }
    }

    /// Generic dispatcher for non-agent entries (User, System, Compact,
    /// Synthesized.prLink). Goes through the unified `EntryView`, with
    /// the per-kind detail-open handler wired through
    /// ``defaultDetailRequest(for:)``.
    private func genericEntryView(entry: Entry, palette: HudPalette) -> some View {
        let computed = panel.computedCache.compute(for: entry, displayMode: .compact)
        let entryID = entry.id.stableString
        let detailRequest = defaultDetailRequest(for: entry)
        return EntryView(
            entry: entry,
            computed: computed,
            palette: palette,
            displayMode: .compact,
            isExpanded: panel.currentExpanded.contains(entryID),
            isStreaming: false,
            onToggleExpansion: {
                panel.toggleExpansion(.entry(id: entryID))
            },
            onOpenDetail: {
                if let detailRequest {
                    panel.openDetail(request: detailRequest)
                }
            },
            renderSubEntry: { _ in AnyView(EmptyView()) }
        )
        .id(entryID)
    }

    /// Per-kind detail surface mapping. Drives the "↗ Open detail"
    /// link rendered by `EntryBodyView` when an entry's inline body
    /// overflows its caps. Returns nil for entries that have no
    /// detail surface (e.g. PR-link external URL — opening is
    /// handled separately).
    private func defaultDetailRequest(for entry: Entry) -> DetailRequest? {
        let id = entry.id.stableString
        switch entry {
        case .user:
            return .userPrompt(entryID: id)
        case .system(let sys):
            switch sys.subType {
            case .skill:           return .skillBody(entryID: id)
            case .systemReminder:  return .systemReminderBody(entryID: id)
            case .recap:           return .recapBody(entryID: id)
            case .slashCmdInput,
                 .slashCmdOutput:  return .slashCommandBody(entryID: id)
            case .localCommand,
                 .contextUsage,
                 .planMode,
                 .editedTextFile,
                 .other:
                return .systemOutput(entryID: id)
            }
        case .compact:
            return .systemOutput(entryID: id)
        case .synthesized, .agent:
            return nil
        }
    }

    /// Visible turn-boundary divider (predecessor parity per
    /// PARITY §1.7 + dogfood feedback). 1pt SwiftUI `Divider()`
    /// with foreground@0.06 background — visible-but-subtle hairline
    /// that doubles as the `proxy.scrollTo(...)` target.
    private func boundaryDivider(id: String, palette: HudPalette) -> some View {
        Divider()
            .background(Color(nsColor: appearance.foregroundColor).opacity(Theme.Opacity.bgWash))
            .id(id)
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
                   case .branchLink = s.kind { return false }
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
                .font(Theme.Row.name)
                .foregroundStyle(palette.primary)
            Text(emptyDetail)
                .font(Theme.Row.summary)
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

    /// Detail-mode rendering. When `content.entries` is non-nil
    /// (abandoned-branch or sub-agent transcript), render an entries
    /// list using the same EntryView dispatcher used for live
    /// transcripts (in `.fullDetail` mode). Otherwise render the
    /// plain-text body.
    private func detailView(content: DetailContent) -> some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        let icon = detailKindIcon(for: content.kind)
        let accent = detailKindAccent(for: content.kind, palette: palette)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.Spacing.rowIconText) {
                if let icon {
                    Image(systemName: icon)
                        .font(Theme.DetailPanel.heading)
                        .foregroundStyle(accent)
                }
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
            if let entries = content.entries, !entries.isEmpty {
                detailEntriesList(entries: entries, palette: palette)
            } else {
                detailBodyText(content.body, palette: palette)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    /// SF Symbol name for the leading glyph in the detail-mode header,
    /// mapped from `DetailContent.Kind`. Mirrors predecessor mapping.
    private func detailKindIcon(for kind: DetailContent.Kind) -> String? {
        switch kind {
        case .userPrompt:           return EntryIcon.user.collapsed
        case .thinking:             return EntryIcon.thinking.collapsed
        case .systemOutput:         return EntryIcon.system.collapsed
        case .toolInput(let name),
             .toolResult(let name, _):
            return EntryIcon.tool(named: name).collapsed
        case .assistantResponse:    return EntryIcon.agent.collapsed
        case .abandonedBranch:      return EntryIcon.branchLink.collapsed
        case .subagentTranscript:   return EntryIcon.tool(named: "Task").collapsed
        case .skillBody:            return EntryIcon.skill.collapsed
        case .slashCommandBody:     return EntryIcon.slashCommand.collapsed
        case .systemReminderBody:   return EntryIcon.systemReminder.collapsed
        case .recapBody:            return EntryIcon.recap.collapsed
        }
    }

    /// Accent color for the leading glyph, matching the per-kind rules
    /// from `EntryView.kindAccentColor` so the detail header reads as
    /// a continuation of the live entry.
    private func detailKindAccent(for kind: DetailContent.Kind, palette: HudPalette) -> Color {
        switch kind {
        case .userPrompt:                   return palette.blue
        case .thinking, .assistantResponse: return palette.claude
        case .systemOutput, .slashCommandBody, .skillBody, .recapBody:
            return palette.cyan
        case .systemReminderBody:           return palette.yellow
        case .toolResult(_, let isError):
            return isError ? palette.red : palette.primary
        case .toolInput, .subagentTranscript:
            return palette.primary
        case .abandonedBranch:              return palette.dim
        }
    }

    private func detailBodyText(_ body: String, palette: HudPalette) -> some View {
        ScrollView {
            Text(body)
                .font(Theme.DetailPanel.body)
                .foregroundStyle(palette.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Padding.expandedBodyBlock)
        }
    }

    /// Render an entries array (abandoned-branch / sub-agent
    /// transcript) inline using the same EntryView dispatcher used
    /// for live transcripts. Detail mode shows everything expanded;
    /// the open-detail link is a no-op (no nested detail tabs).
    private func detailEntriesList(entries: [Entry], palette: HudPalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Padding.topLevelEntryGap) {
                ForEach(entries, id: \.id.stableString) { entry in
                    detailEntryRow(entry: entry, palette: palette)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }

    private func detailEntryRow(entry: Entry, palette: HudPalette) -> some View {
        let computed = panel.computedCache.compute(for: entry, displayMode: .fullDetail)
        let entryID = entry.id.stableString
        return EntryView(
            entry: entry,
            computed: computed,
            palette: palette,
            displayMode: .fullDetail,
            isExpanded: true,
            isStreaming: false,
            onToggleExpansion: {},
            onOpenDetail: {},
            renderSubEntry: { _ in AnyView(EmptyView()) }
        )
        .id(entryID)
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

// MARK: - Branch-link sub-row

/// Rewind / abandoned-branch link rendered as a compact sub-row
/// (predecessor parity per PARITY §3.15 / dogfood feedback). Layout
/// mirrors the spike's `tangentLeading` chrome:
///
///     [↳] [branch] Rewind X of Y · N entries · <preview>
///       └─ glyph in the gap between parent's icon column and name column
///          └─ branch icon aligns with the parent's NAME column (= where
///             other sub-row icons would land if this were a true sub-row)
///
/// Click → `onOpenDetail(.abandonedBranch(...))` — the abandoned-branch
/// transcript opens in a sibling detail tab.
@available(macOS 15, *)
private struct BranchLinkEntryRow: View {
    let rewindIndex: Int
    let totalRewinds: Int
    let entryCount: Int
    let firstPromptPreview: String?
    let palette: HudPalette
    let onOpenDetail: () -> Void

    var body: some View {
        Button(action: onOpenDetail) {
            HStack(spacing: Theme.Spacing.rowIconText) {
                // Tangent leading: reserve the parent's icon-column
                // width and overlay `↳` at the trailing edge with a
                // half-spacing offset so it lands in the gap between
                // the parent's icon and name columns.
                Color.clear
                    .frame(width: Theme.Metric.rowIconWidth, height: 12)
                    .overlay(alignment: .trailing) {
                        Text("↳")
                            .font(Theme.SubRow.summary)
                            .foregroundStyle(palette.dim)
                            .fixedSize()
                            .offset(x: Theme.Spacing.rowIconText / 2)
                    }
                Image(systemName: EntryIcon.branchLink.collapsed)
                    .font(Theme.SubRow.icon)
                    .foregroundStyle(palette.dim)
                Text(titleText)
                    .font(Theme.SubRow.summary)
                    .foregroundStyle(palette.dim)
                    .underline(true, color: palette.dim.opacity(Theme.Opacity.dim))
                    .lineLimit(1)
                Text("·")
                    .font(Theme.SubRow.summary)
                    .foregroundStyle(palette.dim.opacity(Theme.Opacity.detail))
                Text(subtitleText)
                    .font(Theme.SubRow.summary)
                    .foregroundStyle(palette.dim.opacity(Theme.Opacity.detail))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Padding.horizontal)
            .padding(.vertical, Theme.Spacing.verticalStack)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(palette: palette)
    }

    private var titleText: String {
        String(
            localized: "agentXray.entry.branchLink.title",
            defaultValue: "Rewind \(rewindIndex) of \(totalRewinds)",
            bundle: .module
        )
    }

    private var subtitleText: String {
        let countText = String(
            localized: "agentXray.entry.branchLink.subtitle.count",
            defaultValue: "\(entryCount) entries",
            bundle: .module
        )
        if let preview = firstPromptPreview, !preview.isEmpty {
            return "\(countText) · \(preview)"
        }
        return countText
    }
}
