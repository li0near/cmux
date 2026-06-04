import SwiftUI

/// Unified header renderer. Consumes a `Header` value and renders a
/// horizontal pill row:
///
///     [icon]  [name]  [label]  [title]  [trailing items…]  [timestamp]
///
/// Every Entry variant routes through this same view. Variant-specific
/// effects (queued-pulse, streaming-pulse) ride on top via the
/// `pulseIcon` and `kindAccentColor` parameters provided by `EntryView`'s
/// dispatch — keeping this view itself shape-agnostic.
@available(macOS 15, *)
struct EntryHeaderView: View {

    let header: Header
    let palette: HudPalette
    /// Pulse the icon glyph (queued / streaming state). Driven by the
    /// renderer's external state, not by the Header itself — pulsing
    /// is render-only and orthogonal to the header's data.
    let pulseIcon: Bool
    /// Override color for the icon + name. Nil = palette.primary.
    let kindAccentColor: Color?
    /// Whether the header shows an expanded chevron rotation. Driven
    /// by the dispatcher's `isExpanded` flag.
    let isExpanded: Bool

    init(
        header: Header,
        palette: HudPalette,
        pulseIcon: Bool = false,
        kindAccentColor: Color? = nil,
        isExpanded: Bool = false
    ) {
        self.header = header
        self.palette = palette
        self.pulseIcon = pulseIcon
        self.kindAccentColor = kindAccentColor
        self.isExpanded = isExpanded
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.rowIconText) {
            if let icon = header.icon {
                let symbol = icon.systemName(expanded: isExpanded)
                Image(systemName: symbol)
                    .font(Theme.Row.icon)
                    .foregroundStyle(kindAccentColor ?? palette.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: pulseIcon)
            }
            if let name = header.name {
                Text(name)
                    .font(Theme.Row.name)
                    .foregroundStyle(kindAccentColor ?? palette.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: pulseIcon)
            }
            if let label = header.label {
                Text(label)
                    .font(Theme.Row.meta)
                    .foregroundStyle(palette.dim)
            }
            if let title = header.title {
                Text(title)
                    .font(Theme.Row.summary)
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Spacing.rowIconText)
            ForEach(Array(header.trailing.enumerated()), id: \.offset) { _, item in
                trailingItemView(item)
            }
            if let timestamp = header.timestamp {
                Text(formatTimestamp(timestamp))
                    .font(Theme.Row.meta)
                    .foregroundStyle(palette.dim)
                    .hoverBars(palette: palette)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingItemView(_ item: TrailingItem) -> some View {
        switch item {
        case .text(let s):
            Text(s)
                .font(Theme.Row.meta)
                .foregroundStyle(palette.dim)
        case .pill(let s), .duration(let s), .wordCount(let s):
            MetadataPill(text: s, palette: palette)
                .hoverBars(palette: palette)
        case .statusDot(let kind):
            StatusDotView(kind: kind, palette: palette)
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Inlined pill helper

/// Rounded-rect pill used for header trailing metadata (token counts,
/// word counts, durations, custom labels). Folded inline in
/// `EntryHeaderView.swift` because the header is the only consumer.
@available(macOS 15, *)
private struct MetadataPill: View {
    let text: String
    let palette: HudPalette

    var body: some View {
        Text(text)
            .font(Theme.SubRow.meta)
            .foregroundStyle(palette.dim)
            .padding(.horizontal, Theme.Padding.pillHorizontal)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                    .fill(palette.expandedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                    .stroke(palette.dim.opacity(Theme.Opacity.dim), lineWidth: Theme.Stroke.pill)
            )
    }
}
