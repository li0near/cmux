public import SwiftUI

/// Terminal-styled color palette for the AgentX-ray panel. Resolves
/// against the host's foreground `Color` so colors remain readable
/// on both light and dark themes.
///
/// The package keeps a slim `Color`-based input rather than a full
/// `PanelAppearance` value type — the host adapter passes its
/// terminal-foreground color directly. The palette lives in the View
/// layer, NOT Models, since SwiftUI Color is a view-layer concept.
@available(macOS 15, *)
public struct HudPalette: Sendable, Equatable {
    public let foreground: Color

    public init(foreground: Color) {
        self.foreground = foreground
    }

    public var dim: Color {
        foreground.opacity(0.55)
    }

    public var primary: Color {
        foreground
    }

    public var cyan: Color {
        Self.fixed(red: 0x33, green: 0xCB, blue: 0xCC)
    }

    public var yellow: Color {
        Self.fixed(red: 0xE3, green: 0xB3, blue: 0x41)
    }

    public var green: Color {
        Self.fixed(red: 0x6E, green: 0xC2, blue: 0x4D)
    }

    public var magenta: Color {
        Self.fixed(red: 0xC8, green: 0x70, blue: 0xE5)
    }

    public var red: Color {
        Self.fixed(red: 0xE5, green: 0x6F, blue: 0x6F)
    }

    public var blue: Color {
        Self.fixed(red: 0x7D, green: 0xA9, blue: 0xCC)
    }

    public var claude: Color {
        Self.fixed(red: 0xE7, green: 0x8C, blue: 0x4D)
    }

    /// Soft background used behind expanded inline blocks so they
    /// read as a contained section rather than blending into the entry.
    public var expandedBackground: Color {
        foreground.opacity(0.06)
    }

    /// Per-line background for `+` rows in unified-diff hunks. Resolved
    /// at draw time from `colorScheme`. Light: GitHub Primer `green.0`
    /// (#dafbe1); Dark: `#2ea043` @ 15% (`bgColor.success.muted`).
    public func diffAddedBackground(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 46.0/255, green: 160.0/255, blue: 67.0/255, opacity: 0.15)
            : Color(.sRGB, red: 0xDA/255.0, green: 0xFB/255.0, blue: 0xE1/255.0, opacity: 1.0)
    }

    /// Per-line background for `-` rows in unified-diff hunks. Light:
    /// GitHub Primer `red.0` (#ffebe9); Dark: `#f85149` @ 10%
    /// (`bgColor.danger.muted`).
    public func diffRemovedBackground(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 248.0/255, green: 81.0/255, blue: 73.0/255, opacity: 0.10)
            : Color(.sRGB, red: 0xFF/255.0, green: 0xEB/255.0, blue: 0xE9/255.0, opacity: 1.0)
    }

    private static func fixed(red: Int, green: Int, blue: Int) -> Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }

    /// Resolve an abstract ``PaletteRole`` (Models layer) to a concrete
    /// SwiftUI `Color` against this palette. Lets DetailContent and
    /// other Models/Panel types carry semantic accent intent without
    /// depending on SwiftUI.
    public func color(for role: PaletteRole) -> Color {
        switch role {
        case .primary: return primary
        case .dim:     return dim
        case .cyan:    return cyan
        case .yellow:  return yellow
        case .green:   return green
        case .magenta: return magenta
        case .red:     return red
        case .blue:    return blue
        case .claude:  return claude
        }
    }

    /// Resolve a ``TextStyle`` to its foreground + background rendering
    /// pair. Single source of truth for inline-row rendering
    /// (`AgentEntryView+CappedBody`, `EntryBodyView`); eliminates the
    /// pre-Phase-D divergence where two view files mapped `.thinking`
    /// to two different colors. Diff styles get a tinted background
    /// (light-green / light-red) so old/new blocks read as a hunk;
    /// non-diff styles share `expandedBackground` and stay rounded.
    public func colors(for style: TextStyle) -> (foreground: Color, background: Color) {
        switch style {
        case .normal:        return (primary.opacity(0.85), expandedBackground)
        case .thinking:      return (primary.opacity(0.85), expandedBackground)
        case .error:         return (red, expandedBackground)
        case .codeMonospace: return (primary.opacity(0.85), expandedBackground)
        }
    }
}

/// Glyph vocabulary lifted from claude-hud — single-character
/// indicators that remain readable in monospaced terminal contexts.
public enum HudGlyph {
    public static let runningCircle = "◐"
    public static let completedCheck = "✓"
    public static let activeDot = "●"
    public static let toolArrow = "▸"
    public static let dividerLight = "─"
    public static let blockFull = "█"
    public static let blockEmpty = "░"
    public static let errorCross = "✗"
}
