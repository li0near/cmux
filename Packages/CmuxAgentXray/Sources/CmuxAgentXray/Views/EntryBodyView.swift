import SwiftUI

/// Unified body renderer. Walks `body.sections` and renders each as
/// an inline gray-background text block (with `TextStyle` applied),
/// an inline image link, a tool-reference chip, an offloaded-output
/// link, or a code block (Read tool body / Edit-shape diff hunks).
///
/// Nested children (sub-agent transcripts, abandoned-branch entries,
/// agent turn sub-entries) live on the entry's top-level `subEntries`
/// field, not in `body.sections` — ``EntryView`` walks those directly
/// via ``ExpansionShape/children(_:)`` and never reaches this view for
/// them.
///
/// Caps are pre-applied via ``EntryComputedCache/compute(for:)`` —
/// this view consumes the cached `[ExpandableContent]` rather than
/// running truncation per body pass.
@available(macOS 15, *)
struct EntryBodyView: View {

    let entryBody: Body
    let computed: [ExpandableContent]
    let palette: HudPalette
    /// Detail-tab open callback. Receives the section index so the
    /// caller can construct the right `DetailRequest.bodySection(...)`.
    let onOpenDetail: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
            textSection(content: content, style: style, sectionIndex: computedIndex)
        case .image:
            ImageEntryLinkView(palette: palette) { onOpenDetail(computedIndex) }
        case .toolReference(let toolName):
            ToolReferenceChipView(toolName: toolName, palette: palette)
        case .offloadedOutput(let off):
            OffloadedOutputLinkView(offloaded: off, palette: palette) {
                onOpenDetail(computedIndex)
            }
        case .code(let content):
            CodeBlockView(
                content: content,
                palette: palette,
                onOpenDetail: { onOpenDetail(computedIndex) }
            )
        }
    }

    @ViewBuilder
    private func textSection(content: ExpandableContent, style: TextStyle, sectionIndex: Int) -> some View {
        if !content.inlineBody.isEmpty {
            let colors = palette.colors(for: style)
            Text(content.inlineBody)
                .font(Theme.Entry.title)
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
                action: { onOpenDetail(sectionIndex) }
            )
        }
    }
}
