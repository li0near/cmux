import SwiftUI

/// Unified body renderer. Walks `body.sections` and renders each as
/// either an inline gray-background text block (with `TextStyle`
/// applied) or a recursive sub-entry list.
///
/// Caps are pre-applied via `EntryComputedCache.compute(...)` — this
/// view consumes the cached `[ExpandableContent]` rather than running
/// truncation per body pass.
///
/// Recursion: a `.subentries(...)` section calls back into `EntryView`
/// for each child, which calls back into `EntryBodyView` for grand-
/// children. Recursion is bounded by the JSONL data shape (one level
/// of sub-entries inside AgentEntry; sidechain transcripts add at most
/// one more level for sub-agent calls).
@available(macOS 15, *)
struct EntryBodyView: View {

    let entryBody: Body
    let computed: [ExpandableContent]
    let palette: HudPalette
    let displayMode: DisplayMode
    let onOpenDetail: () -> Void
    let renderSubEntry: (Entry) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entryBody.sections.enumerated()), id: \.offset) { index, section in
                sectionView(section, computedIndex: index)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: Section, computedIndex: Int) -> some View {
        switch section {
        case .text(_, let style):
            let content = computedIndex < computed.count ? computed[computedIndex] : .empty
            textSection(content: content, style: style)
        case .image:
            ImageEntryLinkView(palette: palette, action: onOpenDetail)
        case .toolReference(let toolName):
            ToolReferenceChipView(toolName: toolName, palette: palette)
        case .offloadedOutput(let off):
            OffloadedOutputLinkView(offloaded: off, palette: palette, action: onOpenDetail)
        case .subentries(let children):
            VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
                ForEach(children, id: \.id.stableString) { child in
                    renderSubEntry(child)
                }
            }
        }
    }

    @ViewBuilder
    private func textSection(content: ExpandableContent, style: TextStyle) -> some View {
        if !content.inlineBody.isEmpty {
            let colors = palette.colors(for: style)
            Text(content.inlineBody)
                .font(Theme.SubRow.title)
                .foregroundStyle(colors.foreground)
                .italic(style == .thinking)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Padding.expandedBodyBlock)
                .background(sectionBackground(style: style, color: colors.background))
        }
        if content.overflow {
            OpenDetailLinkView(
                totalLines: content.totalLines,
                palette: palette,
                action: onOpenDetail
            )
        }
    }

    /// Diff styles paint as a flat rectangle so adjacent removed /
    /// added sections look like one contiguous hunk; every other
    /// style keeps its rounded chip.
    @ViewBuilder
    private func sectionBackground(style: TextStyle, color: Color) -> some View {
        switch style {
        case .diffAdded, .diffRemoved:
            Rectangle().fill(color)
        case .normal, .thinking, .error, .codeMonospace:
            RoundedRectangle(cornerRadius: Theme.CornerRadius.expandedBodyBlock)
                .fill(color)
        }
    }
}
