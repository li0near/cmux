import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render an agent sub-entry's text body inline, capped at the
    /// `.standard` size (30 lines / 3 KiB). Truncated body renders inline
    /// in the gray expanded-block; if the input exceeds the cap, a
    /// `↗ Open detail` link routes the full content to a sibling detail
    /// tab via `onOpenDetail`.
    ///
    /// Shared by `toolSection` (input + result blocks),
    /// `thinkingSection`, and `assistantTextSection` so all three
    /// sub-entries get the identical cap-then-overflow shape.
    func cappedTextBlock(
        _ text: String,
        color: Color,
        italic: Bool = false,
        onOpenDetail: @escaping () -> Void
    ) -> some View {
        let content = ExpandableContent.make(
            from: [text],
            caps: .standard,
            displayMode: .compact
        )
        let bodyFont = italic
            ? Theme.SubRow.summary.italic()
            : Theme.SubRow.summary
        return VStack(alignment: .leading, spacing: 2) {
            if !content.inlineBody.isEmpty {
                Text(content.inlineBody)
                    .font(bodyFont)
                    .foregroundStyle(color)
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
    }
}
