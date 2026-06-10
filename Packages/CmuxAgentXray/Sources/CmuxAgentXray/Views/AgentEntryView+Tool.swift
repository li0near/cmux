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
        let isExpanded = actions.isSubEntryExpanded(key)
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
        let timeMarker: TimeMarker? = tool.durationMs.map { .duration($0) }

        VStack(alignment: .leading, spacing: 2) {
            Button {
                actions.onToggleExpansion(.tool(toolID: key))
            } label: {
                subEntryHeader(
                    icon: tool.header.icon,
                    isExpanded: isExpanded,
                    iconColor: statusAccent,
                    nameAccent: statusAccent,
                    name: tool.mcpServer ?? tool.toolName,
                    label: tool.mcpServer != nil ? tool.toolName : nil,
                    title: tool.header.title,
                    timeMarker: timeMarker,
                    extras: {
                        if let chip = tool.subagentType, !chip.isEmpty {
                            Text(chip)
                                .font(Theme.SubEntry.title)
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
                cappedBody(tool.body) { sectionIndex in
                    actions.onOpenDetail(.bodySection(
                        targetID: tool.id.stableString,
                        sectionIndex: sectionIndex
                    ))
                }
                .padding(.leading, Theme.Indent.nestedSubEntry)
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
