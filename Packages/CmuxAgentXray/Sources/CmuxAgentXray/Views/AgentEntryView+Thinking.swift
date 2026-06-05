import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render a thinking sub-entry. Uses the unified `subEntryHeader`
    /// chrome: brain icon + "thinking" name + word-count trailing.
    /// Body uses the shared cap-then-overflow shape: italic gray block
    /// when expanded, with a `↗ Open detail` link when text exceeds
    /// the standard cap.
    @ViewBuilder
    func thinkingSection(thinking: ThinkingEntry) -> some View {
        let key = thinking.id.stableString
        let isExpanded = isSubEntryExpanded(key)
        let body = thinking.body.textContent
        let trailing: [TrailingItem] = thinking.wordCount > 0
            ? [.wordCount("\(thinking.wordCount) words")]
            : []

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.thinking(subEntryID: key))
            } label: {
                subEntryHeader(
                    icon: EntryIcon.thinking,
                    isExpanded: isExpanded,
                    iconColor: palette.dim,
                    nameAccent: palette.dim,
                    name: "thinking",
                    trailing: trailing
                )
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette)

            if isExpanded {
                cappedTextBlock(
                    body,
                    color: palette.dim,
                    italic: true,
                    onOpenDetail: {
                        onOpenDetail(.thinking(
                            entryID: thinking.parentEntryID.stableString,
                            subEntryID: key
                        ))
                    }
                )
                .padding(.leading, Theme.Indent.nestedSubRow)
            }
        }
    }
}
