public import SwiftUI

/// Hover-effect style. ``fill`` paints a faint rounded background;
/// ``stroke`` draws a thin ring. Pills use ``stroke`` so the visible
/// chrome stays focused on the pill itself; row-level click targets
/// use ``fill`` so the whole row reads as the affordance.
@available(macOS 15, *)
public enum HoverEffectStyle: Sendable {
    case fill
    case stroke
}

/// Subtle hover indicator. Applied to icon buttons and sub-entry click
/// targets — pills and bare text labels do **not** get this; their
/// hover affordance is the cursor change alone.
///
/// Renders as a faint rounded background fill (``HoverEffectStyle/fill``)
/// or a thin stroke ring (``HoverEffectStyle/stroke``) tinted with the
/// entry's own accent color (claude orange for assistant turns, blue
/// for user, status-color for tools, etc.) on hover. Falls back to
/// ``HudPalette/dim`` when no accent is supplied. Animation: 0.12s
/// ease-out fade on the effect's opacity.
///
/// An optional `tooltip` string adds a SwiftUI `.help(...)` so the
/// system tooltip surfaces after the standard hover delay. Future
/// callers may also drive tooltips on label-only surfaces (token
/// count pill, timestamp, etc.) by passing a tooltip without
/// adopting the hover chrome — for that, use the modifier directly
/// with `palette = nil`.
@available(macOS 15, *)
public struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    @State private var innerHovering = false
    let palette: HudPalette?
    let accent: Color?
    let style: HoverEffectStyle
    let tooltip: String?

    public init(
        palette: HudPalette? = nil,
        accent: Color? = nil,
        style: HoverEffectStyle = .fill,
        tooltip: String? = nil
    ) {
        self.palette = palette
        self.accent = accent
        self.style = style
        self.tooltip = tooltip
    }

    public func body(content: Content) -> some View {
        let highlighted = content
            .background(fillBackground)
            .overlay(strokeOverlay)
            .onHover { hovering = $0 }
            .onPreferenceChange(InnerHoverPreferenceKey.self) { innerHovering = $0 }
            .preference(key: InnerHoverPreferenceKey.self, value: subtreeHovering)
        return Group {
            if let tooltip {
                highlighted.help(tooltip)
            } else {
                highlighted
            }
        }
    }

    @ViewBuilder
    private var fillBackground: some View {
        if style == .fill {
            RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                .fill(effectColor)
                .opacity(showsEffect ? Theme.Opacity.hoverTint : 0)
                .animation(.easeOut(duration: Theme.Timing.quick), value: showsEffect)
        }
    }

    @ViewBuilder
    private var strokeOverlay: some View {
        if style == .stroke {
            RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                .strokeBorder(effectColor, lineWidth: 1)
                .opacity(showsEffect ? 1 : 0)
                .animation(.easeOut(duration: Theme.Timing.quick), value: showsEffect)
        }
    }

    /// Effect is shown only when a `palette` was supplied, the cursor
    /// is over the target, AND no descendant hover target has claimed
    /// priority (e.g., the token pill takes priority over the row).
    private var showsEffect: Bool {
        palette != nil && hovering && !innerHovering
    }

    /// Resolved hover color. Prefer the caller's supplied accent
    /// (per-kind tint); fall back to ``HudPalette/dim`` (neutral wash).
    private var effectColor: Color {
        accent ?? palette?.dim ?? .clear
    }

    /// Combined "anything in my subtree is being hovered" signal —
    /// published upward via ``InnerHoverPreferenceKey`` so ancestor
    /// hover effects can suppress themselves when a more specific
    /// inner target is active.
    private var subtreeHovering: Bool {
        hovering || innerHovering
    }
}

/// Bubbles "any HoverHighlight in this subtree is currently hovered"
/// signal up the view hierarchy. An ancestor ``HoverHighlight`` reads
/// this preference and suppresses its own visible effect when a
/// nested HoverHighlight has claimed priority — gives precedence to
/// the most-specific click target the cursor is over (token pill
/// inside a row → row hover hides, pill stroke shows).
private struct InnerHoverPreferenceKey: PreferenceKey {
    static let defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

@available(macOS 15, *)
extension View {
    /// Apply the standard hover indicator — a subtle rounded
    /// background or stroke ring on hover plus an optional tooltip.
    /// Pass an `accent` to tint the hover chrome with the entry's
    /// per-kind color (claude orange / blue / status-color / etc.);
    /// omit it for a neutral grey wash. Pass `palette: nil` to attach
    /// a tooltip without the hover chrome (for label-only surfaces).
    public func hoverHighlight(
        palette: HudPalette? = nil,
        accent: Color? = nil,
        style: HoverEffectStyle = .fill,
        tooltip: String? = nil
    ) -> some View {
        modifier(HoverHighlight(palette: palette, accent: accent, style: style, tooltip: tooltip))
    }
}
