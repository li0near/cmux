public import AppKit
public import SwiftUI

/// Terminal-styled color palette for the AgentX-ray panel. Resolves
/// against the host's foreground `NSColor` so colors remain readable
/// on both light and dark themes.
///
/// The package keeps a slim `NSColor`-based input rather than a full
/// `PanelAppearance` value type — the host adapter passes its
/// terminal-foreground color directly. The palette lives in the View
/// layer, NOT Models, since SwiftUI Color is a view-layer concept.
public struct HudPalette: Sendable {
    public let foreground: NSColor

    public init(foreground: NSColor) {
        self.foreground = foreground
    }

    public var dim: Color {
        Color(nsColor: foreground).opacity(0.55)
    }

    public var primary: Color {
        Color(nsColor: foreground)
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
    /// read as a contained section rather than blending into the row.
    public var expandedBackground: Color {
        Color(nsColor: foreground).opacity(0.06)
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
