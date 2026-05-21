import AppKit
import SwiftUI

/// Terminal-styled palette for the Agent Inspector. Mirrors the semantic
/// colour vocabulary used by `claude-hud/src/render/colors.ts` so the
/// inspector reads like a native shell statusline:
///
/// - dim:     metadata, separators, low-priority labels
/// - cyan:    tool names, model labels
/// - yellow:  in-progress / running indicators (◐), branches
/// - green:   completed indicators (✓)
/// - magenta: agent / process names
/// - red:     error / failure
/// - claude:  brand orange for the assistant name banner
///
/// Colors are resolved against the panel's terminal `PanelAppearance` so
/// they remain readable on both light and dark themes.
struct HudPalette {
    let foreground: NSColor

    init(appearance: PanelAppearance) {
        self.foreground = appearance.foregroundColor
    }

    var dim: Color {
        Color(nsColor: foreground).opacity(0.55)
    }

    var primary: Color {
        Color(nsColor: foreground)
    }

    var cyan: Color {
        Self.fixed(red: 0x33, green: 0xCB, blue: 0xCC)
    }

    var yellow: Color {
        Self.fixed(red: 0xE3, green: 0xB3, blue: 0x41)
    }

    var green: Color {
        Self.fixed(red: 0x6E, green: 0xC2, blue: 0x4D)
    }

    var magenta: Color {
        Self.fixed(red: 0xC8, green: 0x70, blue: 0xE5)
    }

    var red: Color {
        Self.fixed(red: 0xE5, green: 0x6F, blue: 0x6F)
    }

    var blue: Color {
        Self.fixed(red: 0x7D, green: 0xA9, blue: 0xCC)
    }

    var claude: Color {
        Self.fixed(red: 0xE7, green: 0x8C, blue: 0x4D)
    }

    /// Soft background used behind expanded inline blocks (thinking, tool
    /// input/result, full user prompt) so they read as a contained section
    /// rather than blending into the row.
    var expandedBackground: Color {
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

/// Glyph vocabulary lifted from claude-hud — single-character indicators that
/// remain readable in monospaced terminal contexts.
enum HudGlyph {
    static let runningCircle = "◐"
    static let completedCheck = "✓"
    static let activeDot = "●"
    static let toolArrow = "▸"
    static let dividerLight = "─"
    static let blockFull = "█"
    static let blockEmpty = "░"
    static let errorCross = "✗"
}
