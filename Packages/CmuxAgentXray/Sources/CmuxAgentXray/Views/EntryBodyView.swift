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
            Text(content.inlineBody)
                .font(Theme.Row.summary)
                .foregroundStyle(textColor(for: style))
                .italic(style == .thinking)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Padding.expandedBodyBlock)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.expandedBodyBlock)
                        .fill(palette.expandedBackground)
                )
        }
        if content.overflow {
            OpenDetailLinkView(
                totalLines: content.totalLines,
                palette: palette,
                action: onOpenDetail
            )
        }
    }

    private func textColor(for style: TextStyle) -> Color {
        switch style {
        case .normal:   return palette.primary.opacity(0.85)
        case .thinking: return palette.dim
        case .error:    return palette.red
        }
    }
}
