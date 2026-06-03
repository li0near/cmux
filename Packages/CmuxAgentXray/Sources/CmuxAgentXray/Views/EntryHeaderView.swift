import SwiftUI

/// Unified header renderer. Consumes a `Header` value and renders a
/// horizontal pill row:
///
///     [icon]  [name]  [label]  [title]  [trailing items…]  [timestamp]
///
/// Every Entry variant routes through this same view. Variant-specific
/// effects (queued-pulse, streaming-pulse) ride on top via the
/// `pulseIcon` and `accentColor` parameters provided by `EntryView`'s
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
    let accentColor: Color?
    /// Whether the header shows an expanded chevron rotation. Driven
    /// by the dispatcher's `isExpanded` flag.
    let isExpanded: Bool

    init(
        header: Header,
        palette: HudPalette,
        pulseIcon: Bool = false,
        accentColor: Color? = nil,
        isExpanded: Bool = false
    ) {
        self.header = header
        self.palette = palette
        self.pulseIcon = pulseIcon
        self.accentColor = accentColor
        self.isExpanded = isExpanded
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon = header.icon {
                let symbol = icon.systemName(expanded: isExpanded)
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor ?? palette.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: pulseIcon)
            }
            if let name = header.name {
                Text(name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor ?? palette.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: pulseIcon)
            }
            if let label = header.label {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
            }
            if let title = header.title {
                Text(title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            ForEach(Array(header.trailing.enumerated()), id: \.offset) { _, item in
                trailingItemView(item)
            }
            if let timestamp = header.timestamp {
                Text(formatTimestamp(timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingItemView(_ item: TrailingItem) -> some View {
        switch item {
        case .text(let s):
            Text(s)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.dim)
        case .pill(let s):
            MetadataPillView(text: s, palette: palette)
        case .statusDot(let kind):
            StatusDotView(kind: kind, palette: palette)
        case .duration(let s), .wordCount(let s):
            MetadataPillView(text: s, palette: palette)
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
