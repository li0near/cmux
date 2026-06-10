import SwiftUI

/// Unified header renderer for every entry — top-level and sub-entry
/// alike. Consumes a ``Header`` value plus per-instance render hints
/// (accent color, emphasis, chip, pulse, expansion state) and renders
/// a horizontal pill row:
///
///     [icon]  [name]  [label]  [chip?]  [title]  [trailing items…]  [timeMarker]
///
/// Per-Entry-kind specifics (Claude orange for assistant turns, status
/// accent for tools, semibold name for top-level kinds, magenta chip
/// for Task tools) are decided at the dispatcher (``EntryView``) and
/// passed in here as already-resolved values. The header itself stays
/// shape-agnostic.
@available(macOS 15, *)
struct EntryHeaderView: View {

    let header: Header
    let palette: HudPalette
    /// Foreground for the icon and the name. Caller resolves from
    /// ``PaletteRole/forEntry(_:)`` against the palette.
    let accent: Color
    /// True → render the name with semibold weight (``Theme/Entry/nameEmphasis``).
    /// False → regular weight (``Theme/Entry/nameRegular``).
    let emphasized: Bool
    /// Optional inline chip shown between `label` and `title`. Today
    /// only the Task tool's `subagent_type` populates it.
    let chip: HeaderChipDisplay?
    /// Pulse the icon glyph (queued / streaming / pending state).
    let pulseIcon: Bool
    /// Whether the header shows an expanded chevron rotation. Drives
    /// the ``EntryIcon/systemName(expanded:)`` lookup.
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.entryIconText) {
            if let icon = header.icon {
                Image(systemName: icon.systemName(expanded: isExpanded))
                    .font(Theme.Entry.icon)
                    .foregroundStyle(accent)
                    .frame(width: Theme.Metric.entryIconWidth, alignment: .leading)
                    .symbolEffect(.pulse, options: .repeating, isActive: pulseIcon)
            }
            if let name = header.name {
                Text(name)
                    .font(emphasized ? Theme.Entry.nameEmphasis : Theme.Entry.nameRegular)
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            if let label = header.label {
                Text(label)
                    .font(Theme.Entry.meta)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
            }
            if let chip {
                Text(chip.text)
                    .font(Theme.Entry.title)
                    .foregroundStyle(chip.color)
                    .lineLimit(1)
            }
            if let title = header.title {
                Text(title)
                    .font(Theme.Entry.title)
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.tight)
            ForEach(Array(header.trailing.enumerated()), id: \.offset) { _, item in
                trailingItemView(item)
            }
            if let marker = header.timeMarker {
                Text(marker.displayString)
                    .font(Theme.Entry.meta)
                    .foregroundStyle(palette.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingItemView(_ item: TrailingItem) -> some View {
        switch item {
        case .text(let s):
            Text(s)
                .font(Theme.Entry.meta)
                .foregroundStyle(palette.dim)
        case .pill(let s), .wordCount(let s):
            MetadataPill(text: s, palette: palette)
        case .statusDot(let kind):
            StatusDotView(kind: kind, palette: palette)
        case .tokenPill(let usage):
            TokenPillView(usage: usage, palette: palette)
        }
    }
}

/// Per-render chip parameters resolved by the caller. The chip's
/// `Color` is resolved against the host palette upstream so the
/// header stays unaware of palette dispatch.
@available(macOS 15, *)
struct HeaderChipDisplay: Equatable {
    let text: String
    let color: Color
}

// MARK: - Inlined pill helpers

/// Rounded-rect pill used for header trailing metadata (token counts,
/// word counts, durations, custom labels). Sizes to text content.
@available(macOS 15, *)
private struct MetadataPill: View {
    let text: String
    let palette: HudPalette

    var body: some View {
        Text(text)
            .font(Theme.Entry.meta)
            .foregroundStyle(palette.dim)
            .padding(.horizontal, Theme.Padding.pillHorizontal)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                    .fill(palette.expandedBackground)
            )
    }
}

/// Rounded-rect pill that toggles between the compact total
/// ("32.9k tokens") and the per-bucket breakdown
/// ("12.0k in · 1.5k out · 19.4k cr"). Local `@State` per pill
/// instance — each AgentEntry's header carries its own toggle without
/// pushing state up to the panel.
@available(macOS 15, *)
private struct TokenPillView: View {
    let usage: AgentEntry.TokenUsage
    let palette: HudPalette
    @State private var expanded: Bool = false

    var body: some View {
        Button(action: { expanded.toggle() }) {
            Text(expanded ? breakdownLabel : compactLabel)
                .font(Theme.Entry.meta)
                .foregroundStyle(palette.dim)
                .padding(.horizontal, Theme.Padding.pillHorizontal)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                        .fill(palette.expandedBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(palette: palette, style: .stroke)
    }

    private var compactLabel: String {
        formatTokenCounts(usage) + " tokens"
    }

    private var breakdownLabel: String {
        var parts: [String] = []
        if usage.inputTokens > 0        { parts.append("\(formatTokens(usage.inputTokens)) in") }
        if usage.outputTokens > 0       { parts.append("\(formatTokens(usage.outputTokens)) out") }
        if usage.cacheReadTokens > 0    { parts.append("\(formatTokens(usage.cacheReadTokens)) cr") }
        if usage.cacheCreationTokens > 0 { parts.append("\(formatTokens(usage.cacheCreationTokens)) cw") }
        return parts.joined(separator: " · ")
    }
}
