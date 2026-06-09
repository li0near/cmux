import SwiftUI

/// Unified body renderer. Walks `body.sections` and renders each as
/// an inline gray-background text block (with `TextStyle` applied),
/// an inline image link, a tool-reference chip, or an offloaded-output
/// link.
///
/// Nested children (sub-agent transcripts, abandoned-branch entries,
/// agent turn sub-entries) are NO LONGER a body concern post-G1.5 —
/// they live on the entry's top-level `subEntries` field. Container
/// variants (`.agent`, `.synthesized`, `.tool`) project them through
/// `Entry.subEntries`; renderers walk that directly outside this view.
///
/// Caps are pre-applied via `EntryComputedCache.compute(...)` — this
/// view consumes the cached `[ExpandableContent]` rather than running
/// truncation per body pass.
@available(macOS 15, *)
struct EntryBodyView: View {

    let entryBody: Body
    let computed: [ExpandableContent]
    let palette: HudPalette
    let displayMode: DisplayMode
    let onOpenDetail: () -> Void

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
        case .diffHunks(let hunks):
            DiffHunkView(
                hunks: hunks,
                palette: palette,
                onOpenDetail: onOpenDetail
            )
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
                .background(Rectangle().fill(colors.background))
        }
        if content.overflow {
            OpenDetailLinkView(
                totalLines: content.totalLines,
                palette: palette,
                action: onOpenDetail
            )
        }
    }
}
