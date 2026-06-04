import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render a tool-invocation sub-entry. Header carries icon + tool
    /// name + optional sub-agent chip + title (file path or summary)
    /// + duration. Expanded body: input + result text in gray blocks
    /// (red on error). Tool status drives icon + name color via the
    /// 3-state convention from dogfood feedback #8:
    ///   `.pending` → pulsing yellow (in-flight call)
    ///   `.ok`      → green (completed)
    ///   `.error`   → red (failed)
    @ViewBuilder
    func toolSection(tool: ToolEntry) -> some View {
        let key = tool.id.stableString
        let isExpanded = isSubEntryExpanded(key)
        let toolName = tool.toolName
        let title = tool.header.title ?? ""
        let isError = tool.status == .error
        let isPending = tool.status == .pending
        let durationText: String? = tool.durationMs.map { "\($0) ms" }
        /// Shared 3-state accent for icon + name. Predecessor coloured
        /// only the icon by status (name stayed primary), but per
        /// dogfood feedback we keep them symmetric: `.error` → red,
        /// `.pending` → yellow (icon also pulses), `.ok` → green.
        let statusAccent: Color = {
            switch tool.status {
            case .error:   return palette.red
            case .pending: return palette.yellow
            case .ok:      return palette.green
            }
        }()

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.tool(toolID: key))
            } label: {
                HStack(spacing: Theme.Spacing.subRowIconText) {
                    if let icon = tool.header.icon {
                        Image(systemName: icon.systemName(expanded: isExpanded))
                            .font(Theme.SubRow.icon)
                            .foregroundStyle(statusAccent)
                            .symbolEffect(
                                .pulse,
                                options: .repeating,
                                isActive: isPending
                            )
                    }
                    Text(toolName)
                        .font(Theme.Row.name)
                        .foregroundStyle(statusAccent)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette)

            if isExpanded {
                let inputDetail = tool.inputDetail ?? ""
                let resultDetail = tool.resultDetail ?? ""
                VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
                    if !inputDetail.isEmpty {
                        cappedTextBlock(
                            inputDetail,
                            color: palette.primary.opacity(0.85),
                            onOpenDetail: {
                                onOpenDetail(.toolInput(entryID: parentEntryIDString(of: tool), toolEntryID: tool.id.stableString))
                            }
                        )
                    }
                    if !resultDetail.isEmpty {
                        cappedTextBlock(
                            resultDetail,
                            color: isError ? palette.red : palette.primary.opacity(0.85),
                            onOpenDetail: {
                                onOpenDetail(.toolResult(entryID: parentEntryIDString(of: tool), toolEntryID: tool.id.stableString))
                            }
                        )
                    }
                }
                .padding(.leading, Theme.Indent.nestedSubRow)
            }
        }
    }

    /// Tool input/result with `.standard` caps (30 lines / 3 KiB).
    /// Truncated body renders inline; if overflow, a ↗ "Open detail"
    /// link routes the full content to a sibling detail tab.
    private func cappedTextBlock(
        _ text: String,
        color: Color,
        onOpenDetail: @escaping () -> Void
    ) -> some View {
        let content = ExpandableContent.make(
            from: [text],
            caps: .standard,
            displayMode: .compact
        )
        return VStack(alignment: .leading, spacing: 2) {
            if !content.inlineBody.isEmpty {
                Text(content.inlineBody)
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
            if content.overflow {
                OpenDetailLinkView(
                    totalLines: content.totalLines,
                    palette: palette,
                    action: onOpenDetail
                )
            }
        }
    }

    /// Resolve the parent agent-entry id for a tool. The tool's own
    /// id is the JSONL `tool_use_id`; the panel's `currentEntry`
    /// (this view's `entry`) is the agent turn that contains it.
    private func parentEntryIDString(of tool: ToolEntry) -> String {
        // ToolEntry doesn't carry parentEntryID directly; the
        // AgentEntryView already has `entry` which IS the parent
        // turn. Use that.
        entry.id.stableString
    }
}
