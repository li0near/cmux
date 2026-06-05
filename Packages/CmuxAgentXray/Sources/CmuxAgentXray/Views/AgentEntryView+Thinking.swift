import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render the thinking sub-entry (one per agent turn, when present).
    /// Header: brain icon + "thinking" label + "· N lines" subtitle.
    /// Expanded body: italic gray-block reasoning text.
    @ViewBuilder
    func thinkingSection(thinking: ThinkingEntry, parentEntryID: String) -> some View {
        let key = EntryID.derived(parent: parentEntryID, kind: "thinking").stableString
        let isExpanded = isSubEntryExpanded(key)
        let body = thinking.body.textContent
        let lineCount = body.split(separator: "\n", omittingEmptySubsequences: false).count

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.thinking(parentEntryID: parentEntryID))
            } label: {
                HStack(spacing: Theme.Spacing.subRowIconText) {
                    Image(systemName: EntryIcon.thinking.systemName(expanded: isExpanded))
                        .font(Theme.SubRow.icon)
                        .foregroundStyle(palette.dim)
                        .frame(width: Theme.Metric.subRowIconWidth)
                    Text("thinking")
                        .font(Theme.SubRow.name)
                        .foregroundStyle(palette.dim)
                    Text("· \(lineCount) lines")
                        .font(Theme.SubRow.summary)
                        .foregroundStyle(palette.dim.opacity(Theme.Opacity.detail))
                    Spacer(minLength: 0)
                }
                .padding(.leading, Theme.Indent.subRow)
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette)

            if isExpanded {
                Text(body)
                    .font(Theme.SubRow.summary.italic())
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Padding.expandedBodyBlock)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.expandedBodyBlock)
                            .fill(palette.expandedBackground)
                    )
                    .padding(.leading, Theme.Indent.nestedSubRow)
                    .textSelection(.enabled)
            }
        }
    }
}
