import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render an assistant-text sub-entry. Uses the unified
    /// `subEntryHeader` chrome: microbe.circle icon (claude color) +
    /// "assistant" name + word-count trailing. Body uses the shared
    /// cap-then-overflow shape — multiple assistant-text sub-entries
    /// can appear in one turn (interleaved with tools / thinking) and
    /// each toggles independently.
    @ViewBuilder
    func assistantTextSection(assistantText: AssistantTextEntry) -> some View {
        let key = assistantText.id.stableString
        let isExpanded = isSubEntryExpanded(key)
        let body = assistantText.body.textContent
        let trailing: [TrailingItem] = assistantText.wordCount > 0
            ? [.wordCount("\(assistantText.wordCount) words")]
            : []

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.assistantText(subEntryID: key))
            } label: {
                subEntryHeader(
                    icon: EntryIcon.assistantText,
                    isExpanded: isExpanded,
                    iconColor: palette.claude,
                    nameAccent: palette.claude,
                    name: "assistant",
                    trailing: trailing
                )
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette)

            if isExpanded {
                cappedTextBlock(
                    body,
                    color: palette.primary.opacity(0.85),
                    onOpenDetail: {
                        onOpenDetail(.assistantResponse(
                            entryID: assistantText.parentEntryID.stableString,
                            subEntryID: key
                        ))
                    }
                )
                .padding(.leading, Theme.Indent.nestedSubRow)
            }
        }
    }
}
