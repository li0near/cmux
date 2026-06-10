public import SwiftUI

/// Subtle hover indicator. Applied to icon buttons and sub-entry click
/// targets — pills and bare text labels do **not** get this; their
/// hover affordance is the cursor change alone.
///
/// Renders as a faint rounded background fill on hover (predecessor
/// uses top + bottom hairlines; we tried bars and switched to
/// background-highlight per dogfood feedback). Animation: 0.12s
/// ease-out — snappy without feeling jittery.
///
/// An optional `tooltip` string adds a SwiftUI `.help(...)` so the
/// system tooltip surfaces after the standard hover delay. Future
/// callers may also drive tooltips on label-only surfaces (token
/// count pill, timestamp, etc.) by passing a tooltip without
/// adopting the hover-fill chrome — for that, use the modifier
/// directly with `palette = nil`.
@available(macOS 15, *)
public struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    let palette: HudPalette?
    let tooltip: String?

    public init(palette: HudPalette? = nil, tooltip: String? = nil) {
        self.palette = palette
        self.tooltip = tooltip
    }

    public func body(content: Content) -> some View {
        let highlighted = content
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                    .fill(highlightFill)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            )
            .onHover { hovering = $0 }
        return Group {
            if let tooltip {
                highlighted.help(tooltip)
            } else {
                highlighted
            }
        }
    }

    private var highlightFill: Color {
        guard let palette else { return .clear }
        return palette.dim.opacity(hovering ? 0.10 : 0)
    }
}

@available(macOS 15, *)
extension View {
    /// Apply the standard hover indicator — subtle background
    /// highlight on hover plus an optional tooltip. Pass
    /// `palette: nil` to attach a tooltip without the hover-fill
    /// chrome (for label-only surfaces).
    public func hoverHighlight(
        palette: HudPalette? = nil,
        tooltip: String? = nil
    ) -> some View {
        modifier(HoverHighlight(palette: palette, tooltip: tooltip))
    }
}
