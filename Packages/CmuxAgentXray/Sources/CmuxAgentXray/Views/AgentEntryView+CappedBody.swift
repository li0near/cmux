import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render every `.text` section of a sub-entry's `Body` capped at
    /// `.standard` (30 lines / 3 KiB). Each section inherits its
    /// `TextStyle` (`.normal` → primary text, `.thinking` → dim italic,
    /// `.error` → red), and emits its own `↗ Open detail` link on
    /// overflow with the section's index passed back to `onOpenDetail`.
    ///
    /// Shared by every sub-entry view (`toolSection`, `textSection`).
    /// `.subentries` sections inside a body (e.g. tool sub-agent
    /// transcripts) are skipped by this helper — those surface via
    /// other paths today and don't participate in the cap-then-overflow
    /// inline rendering.
    func cappedBody(
        _ body: Body,
        onOpenDetail: @escaping (_ sectionIndex: Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(body.sections.enumerated()), id: \.offset) { idx, section in
                if case .text(let blocks, let style) = section {
                    cappedTextSection(
                        text: blocks.joined(separator: "\n"),
                        style: style,
                        onOpenDetail: { onOpenDetail(idx) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func cappedTextSection(
        text: String,
        style: TextStyle,
        onOpenDetail: @escaping () -> Void
    ) -> some View {
        let content = ExpandableContent.make(
            from: [text],
            caps: .standard,
            displayMode: .compact
        )
        if !content.inlineBody.isEmpty {
            Text(content.inlineBody)
                .font(font(for: style))
                .foregroundStyle(color(for: style))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Padding.expandedBodyBlock)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.expandedBodyBlock)
                        .fill(palette.expandedBackground)
                )
                .textSelection(.enabled)
        }
        if content.overflow {
            OpenDetailLinkView(
                totalLines: content.totalLines,
                palette: palette,
                action: onOpenDetail
            )
        }
    }

    private func color(for style: TextStyle) -> Color {
        switch style {
        case .normal:    return palette.primary.opacity(0.85)
        case .thinking:  return palette.primary.opacity(0.85)
        case .error:     return palette.red
        }
    }

    private func font(for style: TextStyle) -> Font {
        style == .thinking
            ? Theme.SubRow.title.italic()
            : Theme.SubRow.title
    }
}
