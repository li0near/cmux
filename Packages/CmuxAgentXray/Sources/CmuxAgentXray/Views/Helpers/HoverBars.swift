public import SwiftUI

/// Top + bottom 1pt hairline overlay that fades in on hover. Applied
/// uniformly to every interactive surface (frame-less and framed)
/// so the cursor's affordance is consistent across the panel — pills,
/// status-bar buttons, header timestamp, scroll-mode pill, the
/// "↗ assistant response" link, and any future clickable surface.
///
/// Animation duration 0.12s — snappy without feeling jittery.
@available(macOS 15, *)
public struct HoverBars: ViewModifier {
    @State private var hovering = false
    let palette: HudPalette

    public init(palette: HudPalette) {
        self.palette = palette
    }

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .top)    { bar(visible: hovering) }
            .overlay(alignment: .bottom) { bar(visible: hovering) }
            .onHover { hovering = $0 }
    }

    private func bar(visible: Bool) -> some View {
        Rectangle()
            .fill(palette.primary)
            .frame(height: 1)
            .opacity(visible ? Theme.Opacity.dim : 0)
            .animation(.easeOut(duration: 0.12), value: visible)
    }
}

@available(macOS 15, *)
extension View {
    /// Apply the standard HoverBars top + bottom hairline indicator.
    /// See ``HoverBars``.
    public func hoverBars(palette: HudPalette) -> some View {
        modifier(HoverBars(palette: palette))
    }
}
