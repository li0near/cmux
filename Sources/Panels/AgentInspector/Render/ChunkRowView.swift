import SwiftUI

/// Detail-route request emitted when the user clicks `↗ Open detail` on an
/// expandable section that exceeds the inline cap. The parent
/// (`AgentInspectorPanelView`) translates this into a workspace action that
/// opens a sibling `AgentInspectorDetailPanel` tab in the same pane.
enum InspectorDetailRequest: Equatable {
    case userPrompt(chunkId: String)
    case thinking(chunkId: String)
    case systemOutput(chunkId: String)
    case toolInput(chunkId: String, toolId: String)
    case toolResult(chunkId: String, toolId: String)
}

/// One row in the Agent Inspector chunk list.
///
/// **Snapshot-boundary policy applies (CLAUDE.md):** the row holds only
/// immutable value snapshots and stable closure references — never an
/// `@ObservedObject`, `@EnvironmentObject`, `@Bindable`, `@StateObject`, or a
/// stored reference to any store. Custom `Equatable` allows SwiftUI to skip
/// body re-evaluation across orthogonal state changes.
///
/// Per-row expansion state lives in a per-instance `@State` set that does
/// not violate the snapshot boundary (no observable is referenced from below
/// the row line — `@State` is SwiftUI's local view-state vehicle).
struct ChunkRowView: View, Equatable {
    let snapshot: ChunkRowSnapshot
    let palette: HudPaletteToken
    /// Id of the AI chunk currently streaming. When this matches the
    /// snapshot's id, the AI row's header glyph pulses. Snapshot-policy
    /// safe — plain value type.
    let streamingAIChunkId: String?
    /// Stable closure reference. Ignored by `==` per the snapshot policy.
    let onOpenDetail: (InspectorDetailRequest) -> Void

    static func == (lhs: ChunkRowView, rhs: ChunkRowView) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.palette == rhs.palette
            && lhs.streamingAIChunkId == rhs.streamingAIChunkId
    }

    var body: some View {
        switch snapshot.kind {
        case .user:
            UserChunkRow(snapshot: snapshot, palette: palette, onOpenDetail: onOpenDetail)
        case .ai:
            AIChunkRow(
                snapshot: snapshot,
                palette: palette,
                isStreaming: streamingAIChunkId == snapshot.id,
                onOpenDetail: onOpenDetail
            )
        case .system:
            SystemChunkRow(snapshot: snapshot, palette: palette, onOpenDetail: onOpenDetail)
        case .compact:
            CompactChunkRow(snapshot: snapshot, palette: palette)
        }
    }
}

// MARK: - User row

private struct UserChunkRow: View {
    let snapshot: ChunkRowSnapshot
    let palette: HudPaletteToken
    let onOpenDetail: (InspectorDetailRequest) -> Void
    @State private var expanded = false

    private var hasMore: Bool {
        snapshot.userFull.totalLines > 1 || snapshot.userCharCount > snapshot.userPrimary.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { if hasMore { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    typeIcon(
                        systemName: InspectorIcon.user.systemName(expanded: expanded && hasMore),
                        color: palette.kindColor(for: .user)
                    )
                    Text("User")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.kindColor(for: .user))
                    Text(snapshot.userPrimary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    metadataPill("\(snapshot.userCharCount) chars", palette: palette)
                    Text(formatTime(snapshot.timestamp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded && !snapshot.userFull.isEmpty {
                Text(snapshot.userFull.inlineBody)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(palette.expandedBackground)
                    .padding(.leading, expandedIndent)
                if snapshot.userFull.overflow {
                    openDetailLink(palette: palette, totalLines: snapshot.userFull.totalLines) {
                        onOpenDetail(.userPrompt(chunkId: snapshot.id))
                    }
                    .padding(.leading, expandedIndent)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AI row

private struct AIChunkRow: View {
    let snapshot: ChunkRowSnapshot
    let palette: HudPaletteToken
    /// Drives the pulse animation on the header glyph while the trailing
    /// AI chunk is still being written.
    let isStreaming: Bool
    let onOpenDetail: (InspectorDetailRequest) -> Void
    @State private var aiExpanded = true
    @State private var thinkingExpanded = false
    @State private var showDurationInHeader = false
    /// Independent of `aiExpanded` — the tokens segment toggles between
    /// total (default) and per-bucket breakdown when clicked.
    @State private var tokensExpanded = false
    /// Per-tool expansion override. nil → use default (collapsed,
    /// regardless of status — red glyph + red name flag errors); non-nil
    /// is the user's explicit toggle.
    @State private var toolExpansionOverrides: [String: Bool] = [:]

    private func isToolExpanded(_ tool: ChunkRowSnapshot.ToolCallSnapshot) -> Bool {
        if let override = toolExpansionOverrides[tool.id] { return override }
        return false
    }

    private func toggleTool(_ tool: ChunkRowSnapshot.ToolCallSnapshot) {
        let current = isToolExpanded(tool)
        toolExpansionOverrides[tool.id] = !current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if aiExpanded {
                if let thinking = snapshot.thinking {
                    thinkingSection(thinking)
                }
                if !snapshot.toolCalls.isEmpty {
                    ForEach(snapshot.toolCalls) { tool in
                        toolCallRow(tool)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// AI chunk header — has THREE independent click targets that share the
    /// same row:
    ///   1. **Row body** (anywhere not covered by the inner Buttons) →
    ///      toggles `aiExpanded` (show/hide thinking + tools).
    ///   2. **Tokens segment Button** → toggles `tokensExpanded` (compact
    ///      total ↔ per-bucket breakdown).
    ///   3. **Trailing time/duration Button** → toggles
    ///      `showDurationInHeader` (timestamp ↔ total turn duration).
    ///
    /// SwiftUI semantics: a `Button` inside a view that has a `.onTapGesture`
    /// modifier consumes its own tap before the gesture fires, so the inner
    /// buttons take precedence. The row-level `onTapGesture` only fires
    /// when neither inner button absorbed the tap.
    private var header: some View {
        HStack(spacing: 8) {
            pulsingTypeIcon(
                systemName: InspectorIcon.ai.systemName(expanded: aiExpanded),
                color: palette.claude,
                isPulsing: isStreaming
            )
            Text(snapshot.modelFriendly ?? snapshot.aiHeaderLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.kindColor(for: .ai))
            tokensSegment
            Spacer(minLength: 8)
            // Trailing time/duration toggle. Has its own button so it consumes
            // the tap before the row-level onTapGesture would fire.
            Button(action: { showDurationInHeader.toggle() }) {
                Text(headerTrailingLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.dim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { aiExpanded.toggle() }
    }

    @ViewBuilder
    private var tokensSegment: some View {
        let hasTokens = !snapshot.tokens.isEmpty
        if hasTokens {
            Text("·")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.dim)
            Button(action: { tokensExpanded.toggle() }) {
                if tokensExpanded {
                    HStack(spacing: 4) {
                        ForEach(Array(snapshot.tokens.labels.enumerated()), id: \.offset) { idx, label in
                            if idx > 0 {
                                Text("·")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(palette.dim)
                            }
                            Text(label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(palette.dim)
                        }
                    }
                    .contentShape(Rectangle())
                } else {
                    Text(snapshot.tokens.compactSummaryLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.dim)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var headerTrailingLabel: String {
        if showDurationInHeader, let secs = snapshot.durationSeconds {
            return formatDuration(secs)
        }
        return formatTime(snapshot.timestamp)
    }

    private func thinkingSection(_ thinking: ChunkRowSnapshot.ExpandableContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: { thinkingExpanded.toggle() }) {
                HStack(spacing: 6) {
                    typeIcon(
                        systemName: InspectorIcon.thinking.systemName(expanded: thinkingExpanded),
                        color: palette.dim
                    )
                    Text("thinking")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.dim)
                    Text("· \(thinking.totalLines) lines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.dim.opacity(0.75))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.leading, expandedIndent)
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(thinking.inlineBody)
                    .font(.system(size: 12, design: .monospaced).italic())
                    .foregroundColor(palette.dim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(palette.expandedBackground)
                    .padding(.leading, expandedIndent + 14)
                if thinking.overflow {
                    openDetailLink(palette: palette, totalLines: thinking.totalLines) {
                        onOpenDetail(.thinking(chunkId: snapshot.id))
                    }
                    .padding(.leading, expandedIndent + 14)
                }
            }
        }
        .padding(.top, 2)
    }

    private func toolCallRow(_ tool: ChunkRowSnapshot.ToolCallSnapshot) -> some View {
        let expanded = isToolExpanded(tool)
        let canExpand = !tool.input.isEmpty || !tool.result.isEmpty
        let iconPair = InspectorIcon.tool(named: tool.name)
        let iconColor = toolStatusColor(status: tool.status, palette: palette)
        return VStack(alignment: .leading, spacing: 2) {
            Button(action: { if canExpand { toggleTool(tool) } }) {
                HStack(spacing: 6) {
                    pulsingTypeIcon(
                        systemName: iconPair.systemName(expanded: expanded && canExpand),
                        color: iconColor,
                        isPulsing: tool.status == .pending
                    )
                    Text(tool.name)
                        .foregroundColor(tool.isError ? palette.red : palette.primary)
                        .lineLimit(1)
                    if let chip = tool.subagentChip {
                        Text(chip)
                            .foregroundColor(palette.magenta)
                            .lineLimit(1)
                    }
                    if !tool.summary.isEmpty {
                        Text(tool.summary)
                            .foregroundColor(palette.primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let durationMs = tool.durationMs {
                        Text(formatToolDuration(durationMs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(palette.dim)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .contentShape(Rectangle())
                .padding(.leading, expandedIndent)
            }
            .buttonStyle(.plain)
            if expanded {
                if !tool.input.isEmpty {
                    expandedBlock(tool.input, color: palette.dim, style: .keyValueBoldKeys) {
                        onOpenDetail(.toolInput(chunkId: snapshot.id, toolId: tool.id))
                    }
                    .padding(.leading, expandedIndent + 14)
                }
                if !tool.result.isEmpty {
                    expandedBlock(
                        tool.result,
                        color: tool.isError ? palette.red : palette.primary.opacity(0.78),
                        style: .plain
                    ) {
                        onOpenDetail(.toolResult(chunkId: snapshot.id, toolId: tool.id))
                    }
                    .padding(.leading, expandedIndent + 14)
                }
            }
        }
        .padding(.top, 2)
    }

    private func expandedBlock(
        _ content: ChunkRowSnapshot.ExpandableContent,
        color: Color,
        style: ExpandedBodyStyle,
        onOpenDetail: @escaping () -> Void
    ) -> some View {
        let baseFont = Font.system(size: 11, design: .monospaced)
        let textView: Text = {
            switch style {
            case .plain:
                return Text(content.inlineBody)
            case .keyValueBoldKeys:
                return Text(boldifyKeyValueLines(content.inlineBody, baseFont: baseFont))
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            textView
                .font(baseFont)
                .foregroundColor(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(palette.expandedBackground)
            if content.overflow {
                openDetailLink(palette: palette, totalLines: content.totalLines, action: onOpenDetail)
            }
        }
    }
}

// MARK: - System row

private struct SystemChunkRow: View {
    let snapshot: ChunkRowSnapshot
    let palette: HudPaletteToken
    let onOpenDetail: (InspectorDetailRequest) -> Void
    @State private var expanded = true

    private var hasBody: Bool { !snapshot.systemBody.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { if hasBody { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    typeIcon(
                        systemName: InspectorIcon.system.systemName(expanded: expanded && hasBody),
                        color: palette.cyan
                    )
                    Text("sys")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.kindColor(for: .system))
                    Spacer(minLength: 8)
                    Text(formatTime(snapshot.timestamp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded && hasBody {
                Text(snapshot.systemBody.inlineBody)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.dim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(palette.expandedBackground)
                    .padding(.leading, expandedIndent)
                if snapshot.systemBody.overflow {
                    openDetailLink(palette: palette, totalLines: snapshot.systemBody.totalLines) {
                        onOpenDetail(.systemOutput(chunkId: snapshot.id))
                    }
                    .padding(.leading, expandedIndent)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compact row

/// Visible boundary chip for a `CompactChunk`. Renders as
/// `─── context compacted at HH:MM:SS ───` centered across the row,
/// dim foreground. The compaction event itself is informational only —
/// the inspector does not gate visibility on it (per Phase B v2's
/// "always show some turn" rule).
private struct CompactChunkRow: View {
    let snapshot: ChunkRowSnapshot
    let palette: HudPaletteToken

    var body: some View {
        HStack(spacing: 8) {
            ruleSegment
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(palette.dim)
                .lineLimit(1)
            ruleSegment
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var label: String {
        "context compacted at \(formatTime(snapshot.timestamp))"
    }

    private var ruleSegment: some View {
        Rectangle()
            .fill(palette.dim.opacity(0.4))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared helpers

/// Indent applied to expanded blocks (thinking, tool input/result, full user
/// prompt) so they sit visually under the row's type-icon column.
private let expandedIndent: CGFloat = 22

private func openDetailLink(
    palette: HudPaletteToken,
    totalLines: Int,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 4) {
            Text("↗ Open detail")
            Text("(\(totalLines) lines)")
                .foregroundColor(palette.dim)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(palette.cyan)
    }
    .buttonStyle(.plain)
    .padding(.top, 2)
}

private func metadataPill(_ text: String, palette: HudPaletteToken) -> some View {
    Text(text)
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(palette.dim)
}

/// Color used to tint a tool's type-icon based on its status. Replaces what
/// was a separate dot indicator (claude-devtools' `BaseItem.tsx:53-60`
/// pattern); the glyph itself becomes the status indicator. Yellow = pending
/// (tool_use without a matching tool_result yet), green = ok, red = error.
private func toolStatusColor(
    status: ChunkRowSnapshot.ToolCallSnapshot.Status,
    palette: HudPaletteToken
) -> Color {
    switch status {
    case .pending: return palette.yellow
    case .ok: return palette.green
    case .error: return palette.red
    }
}

/// Compact SF Symbol identifying the kind of action a row represents.
/// Mirrors claude-devtools' per-item-type Lucide icons (Brain, Wrench, User,
/// Terminal, Layers) but adds finer-grained per-tool icons via
/// `InspectorIcon.tool(named:)`.
private func typeIcon(systemName: String, color: Color) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 11))
        .foregroundColor(color)
        .frame(width: 14, height: 12, alignment: .center)
}

/// Same as `typeIcon`, but pulses while `isPulsing` is true. Used for
/// running tools (`status == .pending`) and the AI header glyph during
/// the trailing AIChunk's streaming window.
@ViewBuilder
private func pulsingTypeIcon(systemName: String, color: Color, isPulsing: Bool) -> some View {
    if isPulsing {
        Image(systemName: systemName)
            .font(.system(size: 11))
            .foregroundColor(color)
            .frame(width: 14, height: 12, alignment: .center)
            .symbolEffect(.pulse, options: .repeating, isActive: true)
    } else {
        Image(systemName: systemName)
            .font(.system(size: 11))
            .foregroundColor(color)
            .frame(width: 14, height: 12, alignment: .center)
    }
}

private func formatToolDuration(_ ms: Int) -> String {
    if ms < 1000 { return "\(ms)ms" }
    let seconds = Double(ms) / 1000
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let minutes = Int(seconds / 60)
    let rem = Int(seconds.truncatingRemainder(dividingBy: 60))
    return String(format: "%dm%02ds", minutes, rem)
}

/// Render a multi-line `key: value` body with the leading `key:` portion of
/// each line in semibold. Used for tool inputs (which the chunk builder
/// formats as one `<key>: <value>` line per top-level field). Per-run fonts
/// are set explicitly to survive the outer `.font(...)` modifier.
private func boldifyKeyValueLines(_ raw: String, baseFont: Font) -> AttributedString {
    var output = AttributedString()
    let pattern = /^([A-Za-z_][A-Za-z0-9_\-]*)\s*:/
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    for (idx, lineSubstring) in lines.enumerated() {
        let line = String(lineSubstring)
        if let match = try? pattern.prefixMatch(in: line) {
            let keyEnd = match.range.upperBound
            var head = AttributedString(String(line[line.startIndex..<keyEnd]))
            head.font = baseFont.bold()
            output.append(head)
            var tail = AttributedString(String(line[keyEnd...]))
            tail.font = baseFont
            output.append(tail)
        } else {
            var plain = AttributedString(line)
            plain.font = baseFont
            output.append(plain)
        }
        if idx < lines.count - 1 {
            var nl = AttributedString("\n")
            nl.font = baseFont
            output.append(nl)
        }
    }
    return output
}

/// Body-style discriminator passed into `expandedBlock` to pick the right
/// inline AttributedString transform.
private enum ExpandedBodyStyle {
    case plain
    case keyValueBoldKeys
}

private func formatTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 1 {
        return String(format: "%dms", Int(seconds * 1000))
    }
    if seconds < 60 {
        return String(format: "%.1fs", seconds)
    }
    let minutes = Int(seconds / 60)
    let remaining = Int(seconds.truncatingRemainder(dividingBy: 60))
    return String(format: "%dm%02ds", minutes, remaining)
}

// MARK: - Palette token

/// Plain-old-data version of `HudPalette` so `ChunkRowView` can stay
/// `Equatable` and observe the snapshot-boundary policy without hauling in
/// `PanelAppearance`.
struct HudPaletteToken: Equatable {
    let primary: Color
    let dim: Color
    let cyan: Color
    let yellow: Color
    let green: Color
    let magenta: Color
    let red: Color
    let blue: Color
    let claude: Color
    let expandedBackground: Color

    static let preview = HudPaletteToken(
        primary: .primary,
        dim: .secondary,
        cyan: .cyan,
        yellow: .yellow,
        green: .green,
        magenta: .purple,
        red: .red,
        blue: .blue,
        claude: .orange,
        expandedBackground: Color.gray.opacity(0.08)
    )

    static func from(_ palette: HudPalette) -> HudPaletteToken {
        HudPaletteToken(
            primary: palette.primary,
            dim: palette.dim,
            cyan: palette.cyan,
            yellow: palette.yellow,
            green: palette.green,
            magenta: palette.magenta,
            red: palette.red,
            blue: palette.blue,
            claude: palette.claude,
            expandedBackground: palette.expandedBackground
        )
    }

    func kindColor(for kind: ChunkRowSnapshot.Kind) -> Color {
        switch kind {
        case .user: return blue
        case .ai: return claude
        case .system: return cyan
        case .compact: return dim
        }
    }
}
