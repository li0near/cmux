public import SwiftUI

/// Top-level live transcript view for an `AgentXrayPanel`. Layout:
///
///     ┌── status bar ────────────────────────────────────────────┐
///     │ ◐  attached <session>            scroll: snap   ↻ … …    │
///     ├── divider (foreground@0.15) ─────────────────────────────┤
///     │ User      <prompt preview…>          [12 words]  HH:mm:ss│
///     │ Claude  Opus 4.6  [4.0M tokens]                  HH:mm:ss│
///     │   thinking · 1 lines                                     │
///     │   ↗ assistant response · 108 words                       │
///     │   Read /foo/bar.swift                            41 ms   │
///     │   ...                                                    │
///     └──────────────────────────────────────────────────────────┘
///
/// Per-row chrome: `.padding(.vertical, 4) .padding(.horizontal, 12)`.
/// Sub-row indent: 22pt.
@available(macOS 15, *)
public struct CmuxAgentXrayPanelView: View {

    @Bindable public var panel: AgentXrayPanel
    public let appearance: HostAppearance

    public init(panel: AgentXrayPanel, appearance: HostAppearance) {
        self.panel = panel
        self.appearance = appearance
    }

    /// Sub-row indent — first-level (thinking / tool / assistantText
    /// rows under an AgentEntry).
    private static let expandedIndent: CGFloat = 22

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
        return HStack(spacing: 8) {
            Text(statusGlyph)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusGlyphColor(palette: palette))
            Text(statusBarTitle)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                scrollModePill(palette: palette)
                rewindIconButton(palette: palette)
                expansionIconButton(palette: palette)
                collapseIconButton(palette: palette)
                expandIconButton(palette: palette)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusGlyph: String {
        panel.resolvedSession != nil ? "◐" : "●"
    }

    private func statusGlyphColor(palette: HudPalette) -> Color {
        panel.resolvedSession != nil ? palette.yellow : palette.dim
    }

    private var statusBarTitle: String {
        if let session = panel.resolvedSession {
            let prefix = String(session.sessionID.prefix(8))
            let cwd = session.cwd ?? ""
            return "attached \(session.agentKind.rawValue) \(prefix)…\(cwd)"
        }
        return String(
            localized: "agentXray.statusBar.detached",
            defaultValue: "no agent session focused",
            bundle: .module
        )
    }

    private func scrollModePill(palette: HudPalette) -> some View {
        let accent: Color = panel.scrollMode == .snap ? palette.green : palette.dim
        return Button {
            panel.scrollMode = panel.scrollMode == .snap ? .free : .snap
        } label: {
            HStack(spacing: 4) {
                Text("scroll:")
                    .foregroundStyle(palette.dim)
                Text(panel.scrollMode.label)
                    .foregroundStyle(accent)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accent.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func rewindIconButton(palette: HudPalette) -> some View {
        let visible = panel.rewindVisibility == .link
        return iconButton(
            systemName: "arrow.uturn.backward.circle",
            color: visible ? palette.cyan : palette.dim
        ) {
            panel.rewindVisibility = panel.rewindVisibility.cycled()
        }
    }

    private func expansionIconButton(palette: HudPalette) -> some View {
        let on = panel.expansionMode == .autoExpand
        return iconButton(
            systemName: "rectangle.expand.vertical",
            color: on ? palette.cyan : palette.dim
        ) {
            panel.expansionMode = panel.expansionMode.cycled()
        }
    }

    private func collapseIconButton(palette: HudPalette) -> some View {
        iconButton(
            systemName: "chevron.up.chevron.down",
            color: panel.canCollapse ? palette.dim : palette.dim.opacity(0.4)
        ) {
            panel.collapseAll()
        }
    }

    private func expandIconButton(palette: HudPalette) -> some View {
        iconButton(
            systemName: "arrow.down.left.and.arrow.up.right",
            color: panel.canExpand ? palette.dim : palette.dim.opacity(0.4)
        ) {
            panel.expandAll()
        }
    }

    private func iconButton(
        systemName: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var topDivider: some View {
        Divider()
            .background(Color(nsColor: appearance.foregroundColor).opacity(0.15))
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id.stableString) { index, entry in
                            if index > 0 { entryDivider }
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

    /// Top-level entry row. Specializes on AgentEntry so its sub-entries
    /// (thinking / tool / assistantText) render with their per-kind
    /// chrome instead of going through the generic `EntryBodyView`
    /// recursion path.
    @ViewBuilder
    private func entryView(for entry: Entry, palette: HudPalette) -> some View {
        switch entry {
        case .agent(let entry):
            agentEntryView(entry: entry, palette: palette)
        default:
            genericEntryView(entry: entry, palette: palette)
        }
    }

    /// Generic dispatcher for non-agent entries (User, System, Compact,
    /// Synthesized). Goes through the unified EntryView.
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
                panel.toggleExpansion(.entryChevron(entryID: entryID))
            },
            onOpenDetail: {},
            renderSubEntry: { _ in AnyView(EmptyView()) }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .id(entryID)
    }

    /// Specialized AgentEntry renderer. Header through EntryHeaderView;
    /// sub-entries dispatch on their typed kind.
    private func agentEntryView(entry: AgentEntry, palette: HudPalette) -> some View {
        let entryID = entry.id.stableString
        let isExpanded = panel.currentExpanded.contains(entryID)
        let isStreaming = panel.streamingEntryID == entryID
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                panel.toggleExpansion(.entryChevron(entryID: entryID))
            }) {
                EntryHeaderView(
                    header: entry.header,
                    palette: palette,
                    pulseIcon: isStreaming,
                    accentColor: palette.claude,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(entry.subEntries, id: \.id.stableString) { sub in
                    subEntryView(sub: sub, parentEntryID: entryID, palette: palette)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .id(entryID)
    }

    /// Dispatch on the typed AgentEntry.SubEntry so each kind gets its
    /// own per-kind layout.
    @ViewBuilder
    private func subEntryView(
        sub: AgentEntry.SubEntry,
        parentEntryID: String,
        palette: HudPalette
    ) -> some View {
        switch sub {
        case .thinking(let t):
            thinkingEntryView(thinking: t, parentEntryID: parentEntryID, palette: palette)
        case .tool(let tool):
            toolEntryView(tool: tool, palette: palette)
        case .assistantText(let a):
            assistantTextEntryView(assistantText: a, palette: palette)
        }
    }

    private func thinkingEntryView(
        thinking: ThinkingEntry,
        parentEntryID: String,
        palette: HudPalette
    ) -> some View {
        let key = EntryID.derived(parent: parentEntryID, kind: "thinking").stableString
        let isExpanded = panel.currentExpanded.contains(key)
        let body = thinking.body.textContent
        let lineCount = body.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                panel.toggleExpansion(.thinking(parentEntryID: parentEntryID))
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.dim)
                    Text("thinking")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.dim)
                    Text("· \(lineCount) lines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.dim.opacity(0.75))
                    Spacer(minLength: 0)
                }
                .padding(.leading, Self.expandedIndent)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(body)
                    .font(.system(size: 12, design: .monospaced).italic())
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(palette.expandedBackground)
                    .padding(.leading, Self.expandedIndent + 14)
                    .textSelection(.enabled)
            }
        }
    }

    private func toolEntryView(tool: ToolEntry, palette: HudPalette) -> some View {
        let key = tool.id.stableString
        let isExpanded = panel.currentExpanded.contains(key)
        let toolName = tool.toolName
        let title = tool.header.title ?? ""
        let isError = tool.status == .error
        let durationText: String? = tool.durationMs.map { "\($0) ms" }
        return VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                panel.toggleExpansion(.tool(toolID: key))
            }) {
                HStack(spacing: 6) {
                    if let icon = tool.header.icon {
                        Image(systemName: icon.systemName(expanded: isExpanded))
                            .font(.system(size: 11))
                            .foregroundStyle(isError ? palette.red : palette.primary)
                    }
                    Text(toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isError ? palette.red : palette.primary)
                        .lineLimit(1)
                    if let chip = tool.subagentType, !chip.isEmpty {
                        Text(chip)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.magenta)
                            .lineLimit(1)
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let durationText {
                        Text(durationText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.dim)
                    }
                }
                .padding(.leading, Self.expandedIndent)
            }
            .buttonStyle(.plain)
            if isExpanded {
                let inputDetail = tool.inputDetail ?? ""
                let resultDetail = tool.resultDetail ?? ""
                VStack(alignment: .leading, spacing: 4) {
                    if !inputDetail.isEmpty {
                        Text(inputDetail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.primary.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(palette.expandedBackground)
                            .textSelection(.enabled)
                    }
                    if !resultDetail.isEmpty {
                        Text(resultDetail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isError ? palette.red : palette.primary.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(palette.expandedBackground)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, Self.expandedIndent + 14)
            }
        }
    }

    private func assistantTextEntryView(
        assistantText: AssistantTextEntry,
        palette: HudPalette
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "microbe.circle")
                .font(.system(size: 11))
                .foregroundStyle(palette.claude)
            Button(action: {
                panel.openDetail(request: .assistantResponse(entryID: assistantText.parentEntryID.stableString))
            }) {
                Text("↗ assistant response · \(assistantText.wordCount) words")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.claude)
                    .underline(true, color: palette.claude.opacity(0.6))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.expandedIndent)
        .padding(.vertical, 1)
    }

    private var entryDivider: some View {
        Divider()
            .background(Color(nsColor: appearance.foregroundColor).opacity(0.06))
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
