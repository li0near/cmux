import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render a tool-invocation sub-entry. Header carries icon + tool
    /// name + optional sub-agent chip + title (file path or summary)
    /// + duration. Expanded body: input + result text in gray blocks
    /// (red on error). Status drives both icon/name color and the
    /// expanded result text color.
    @ViewBuilder
    func toolSection(tool: ToolEntry) -> some View {
        let key = tool.id.stableString
        let isExpanded = isSubEntryExpanded(key)
        let toolName = tool.toolName
        let title = tool.header.title ?? ""
        let isError = tool.status == .error
        let durationText: String? = tool.durationMs.map { "\($0) ms" }
        let nameAccent: Color = isError ? palette.red : palette.primary

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.tool(toolID: key))
            } label: {
                HStack(spacing: Theme.Spacing.subRowIconText) {
                    if let icon = tool.header.icon {
                        Image(systemName: icon.systemName(expanded: isExpanded))
                            .font(Theme.SubRow.icon)
                            .foregroundStyle(nameAccent)
                    }
                    Text(toolName)
                        .font(Theme.Row.name)
                        .foregroundStyle(nameAccent)
                        .lineLimit(1)
                    if let chip = tool.subagentType, !chip.isEmpty {
                        Text(chip)
                            .font(Theme.SubRow.summary)
                            .foregroundStyle(palette.magenta)
                            .lineLimit(1)
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(Theme.Row.summary)
                            .foregroundStyle(palette.primary.opacity(Theme.Opacity.detail))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: Theme.Spacing.tight)
                    if let durationText {
                        Text(durationText)
                            .font(Theme.SubRow.meta)
                            .foregroundStyle(palette.dim)
                    }
                }
                .padding(.leading, Theme.Indent.subRow)
            }
            .buttonStyle(.plain)
            .hoverBars(palette: palette)

            if isExpanded {
                let inputDetail = tool.inputDetail ?? ""
                let resultDetail = tool.resultDetail ?? ""
                VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
                    if !inputDetail.isEmpty {
                        textBlock(inputDetail, color: palette.primary.opacity(0.85))
                    }
                    if !resultDetail.isEmpty {
                        textBlock(
                            resultDetail,
                            color: isError ? palette.red : palette.primary.opacity(0.85)
                        )
                    }
                }
                .padding(.leading, Theme.Indent.nestedSubRow)
            }
        }
    }

    /// Gray-background expanded text block for tool input / result.
    private func textBlock(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Row.summary)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Padding.expandedBodyBlock)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.expandedBodyBlock)
                    .fill(palette.expandedBackground)
            )
            .textSelection(.enabled)
    }
}
