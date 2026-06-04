import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render the assistant-text sub-entry as a header-only "↗ assistant
    /// response · N words" link. Click opens the full text in a sibling
    /// detail tab — never inline. Underlined claude-color link with a
    /// small leading microbe-circle glyph.
    @ViewBuilder
    func assistantTextSection(assistantText: AssistantTextEntry) -> some View {
        HStack(spacing: Theme.Spacing.subRowIconText) {
            Image(systemName: "microbe.circle")
                .font(Theme.SubRow.icon)
                .foregroundStyle(palette.claude)
            Button {
                onOpenDetail(.assistantResponse(entryID: assistantText.parentEntryID.stableString))
            } label: {
                Text("↗ assistant response · \(assistantText.wordCount) words")
                    .font(Theme.SubRow.summary)
                    .foregroundStyle(palette.claude)
                    .underline(true, color: palette.claude.opacity(Theme.Opacity.dim))
            }
            .buttonStyle(.plain)
            .hoverBars(palette: palette)
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Indent.subRow)
        .padding(.vertical, 1)
    }
}
