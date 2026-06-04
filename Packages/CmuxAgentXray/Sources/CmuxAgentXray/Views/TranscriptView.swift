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
            resolvedSessionTitle: resolvedSessionTitle,
            isAttached: panel.resolvedSession != nil,
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Padding.topLevelEntryGap) {
                        ForEach(entries, id: \.id.stableString) { entry in
                            entryView(for: entry, palette: palette)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.topLeading, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Top-level entry dispatcher. AgentEntry takes the specialized
    /// per-kind path; everything else routes through the generic
    /// `EntryView`.
    @ViewBuilder
    private func entryView(for entry: Entry, palette: HudPalette) -> some View {
        switch entry {
        case .agent(let agent):
            AgentEntryView(
                entry: agent,
                palette: palette,
                isExpanded: panel.currentExpanded.contains(agent.id.stableString),
                isStreaming: panel.streamingEntryID == agent.id.stableString,
                isSubEntryExpanded: { panel.currentExpanded.contains($0) },
                onToggleExpansion: { panel.toggleExpansion($0) },
                onOpenDetail: { panel.openDetail(request: $0) }
            )
        default:
            genericEntryView(entry: entry, palette: palette)
        }
    }

    /// Generic dispatcher for non-agent entries (User, System, Compact,
    /// Synthesized). Goes through the unified `EntryView`.
    private func genericEntryView(entry: Entry, palette: HudPalette) -> some View {
        let computed = panel.computedCache.compute(for: entry, displayMode: .compact)
        let entryID = entry.id.stableString
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
            onOpenDetail: {},
            renderSubEntry: { _ in AnyView(EmptyView()) }
        )
        .id(entryID)
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

    private func detailView(content: DetailContent) -> some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        return VStack(alignment: .leading, spacing: 6) {
            Text(content.title)
                .font(Theme.DetailPanel.heading)
                .foregroundStyle(palette.primary)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(Theme.DetailPanel.subtitle)
                    .foregroundStyle(palette.dim)
            }
            ScrollView {
                Text(content.body)
                    .font(Theme.DetailPanel.body)
                    .foregroundStyle(palette.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Padding.expandedBodyBlock)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}
