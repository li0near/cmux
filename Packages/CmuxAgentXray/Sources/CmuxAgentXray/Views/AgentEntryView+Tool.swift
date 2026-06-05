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
        let isError = tool.status == .error
        let isPending = tool.status == .pending
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
        let trailing: [TrailingItem] = tool.durationMs.map {
            [.duration("\($0) ms")]
        } ?? []

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.tool(toolID: key))
            } label: {
                subEntryHeader(
                    icon: tool.header.icon,
                    isExpanded: isExpanded,
                    iconColor: statusAccent,
                    nameAccent: statusAccent,
                    name: tool.toolName,
                    title: tool.header.title,
                    trailing: trailing,
                    extras: {
                        if let chip = tool.subagentType, !chip.isEmpty {
                            Text(chip)
                                .font(Theme.SubRow.summary)
                                .foregroundStyle(palette.magenta)
                                .lineLimit(1)
                        }
                    }
                )
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: isPending
                )
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette)

            if isExpanded {
                let inputDetail = tool.inputDetail ?? ""
                let resultDetail = tool.resultDetail ?? ""
                VStack(alignment: .leading, spacing: 2) {
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
