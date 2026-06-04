public import SwiftUI

/// Top-level live transcript view for an `AgentXrayPanel`. Reads
/// entries from `panel.stream.entries`, projects them into per-entry
/// `Computed` snapshots via `panel.computedCache`, and renders them
/// as a terminal-styled scrollable list of `EntryView` rows.
///
/// **Snapshot-boundary policy:** the `LazyVStack` of rows below holds
/// only immutable value snapshots + stable closures. The row view
/// itself does not import or hold any reference to the panel's
/// `@Observable` state — it sees only a single `EntryComputedCache.Computed`,
/// a `HudPalette` token, and an `Entry` value.
@available(macOS 15, *)
public struct CmuxAgentXrayPanelView: View {

    @Bindable public var panel: AgentXrayPanel
    public let appearance: HostAppearance

    public init(panel: AgentXrayPanel, appearance: HostAppearance) {
        self.panel = panel
        self.appearance = appearance
    }

    public var body: some View {
        switch panel.mode {
        case .live:
            transcriptList
        case .detail(let content):
            detailView(content: content)
        }
    }

    // MARK: - Transcript list

    private var transcriptList: some View {
        let palette = HudPalette(foreground: appearance.foregroundColor)
        let entries = visibleEntries()

        return Group {
            if entries.isEmpty {
                emptyTranscriptView(palette: palette)
            } else {
                ScrollViewReader { _ in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries, id: \.id.stableString) { entry in
                                EntryView(
                                    entry: entry,
                                    computed: panel.computedCache.compute(
                                        for: entry,
                                        displayMode: .compact
                                    ),
                                    palette: palette,
                                    displayMode: .compact,
                                    isExpanded: panel.currentExpanded.contains(
                                        entry.id.stableString
                                    ),
                                    isStreaming: panel.streamingEntryID == entry.id.stableString,
                                    onToggleExpansion: {
                                        panel.toggleExpansion(
                                            .entryChevron(entryID: entry.id.stableString)
                                        )
                                    },
                                    onOpenDetail: {},
                                    renderSubEntry: { sub in AnyView(EmptyView().id(sub.id.stableString)) }
                                )
                                .id(entry.id.stableString)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
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
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.primary)
            Text(emptyDetail)
                .font(.system(size: 12, design: .monospaced))
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
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.primary)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
            }
            ScrollView {
                Text(content.body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}
