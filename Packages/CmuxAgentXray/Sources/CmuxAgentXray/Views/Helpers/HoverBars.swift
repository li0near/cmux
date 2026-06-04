public import SwiftUI

/// Subtle hover indicator. Applied to icon buttons and sub-row click
/// targets — pills and bare text labels do **not** get this; their
/// hover affordance is the cursor change alone.
///
/// Renders as a faint rounded background fill on hover (predecessor
/// uses top + bottom hairlines; we tried bars and switched to
/// background-highlight per dogfood feedback). Animation: 0.12s
/// ease-out — snappy without feeling jittery.
@available(macOS 15, *)
public struct HoverBars: ViewModifier {
    @State private var hovering = false
    let palette: HudPalette

    public init(palette: HudPalette) {
        self.palette = palette
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                    .fill(palette.dim.opacity(hovering ? 0.10 : 0))
                    .animation(.easeOut(duration: 0.12), value: hovering)
            )
            .onHover { hovering = $0 }
    }
}

@available(macOS 15, *)
extension View {
    /// Apply the standard hover indicator — subtle background
    /// highlight on hover. See ``HoverBars``.
    public func hoverBars(palette: HudPalette) -> some View {
        modifier(HoverBars(palette: palette))
    }
}
