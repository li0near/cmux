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
    /// When true, every per-kind accent (`primary`, `cyan`, `yellow`,
    /// `green`, `magenta`, `red`, `blue`, `claude`) collapses to
    /// ``dim``. Used by the abandoned-branch (rewind) subtree: pass
    /// ``dimmed`` to every descendant via the recursion's `palette:`
    /// argument and the entire subtree renders in one inert color
    /// without touching any leaf view. Idempotent — `palette.dimmed.dimmed`
    /// equals `palette.dimmed`, so nested rewinds compose without
    /// compounding.
    public let allColorsDimmed: Bool

    public init(foreground: Color, allColorsDimmed: Bool = false) {
        self.foreground = foreground
        self.allColorsDimmed = allColorsDimmed
    }

    public var dim: Color {
        foreground.opacity(0.55)
    }

    /// Soft background used behind expanded inline blocks so they
    /// read as a contained section rather than blending into the entry.
    public var expandedBackground: Color {
        foreground.opacity(0.06)
    }

    /// A variant where every per-kind accent collapses to ``dim``.
    /// Idempotent: calling `.dimmed` on an already-dimmed palette
    /// returns the same dimmed palette (no compounding).
    public var dimmed: HudPalette {
        allColorsDimmed
            ? self
            : HudPalette(foreground: foreground, allColorsDimmed: true)
    }

    // MARK: - Per-kind accent accessors

    /// Every named accent routes through ``color(for:)`` so the
    /// ``allColorsDimmed`` short-circuit lives in a single place.
    /// Adding a new accent requires one switch arm there — never
    /// remember the dimmed branch separately.
    public var primary: Color { color(for: .primary) }
    public var cyan:    Color { color(for: .cyan) }
    public var yellow:  Color { color(for: .yellow) }
    public var green:   Color { color(for: .green) }
    public var magenta: Color { color(for: .magenta) }
    public var red:     Color { color(for: .red) }
    public var blue:    Color { color(for: .blue) }
    public var claude:  Color { color(for: .claude) }

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
    ///
    /// **Single dim short-circuit lives here.** When
    /// ``allColorsDimmed`` is true, every role except ``PaletteRole/dim``
    /// itself returns ``dim`` — that's how the abandoned-branch fade
    /// flattens accents to one inert color across the whole subtree.
    public func color(for role: PaletteRole) -> Color {
        if allColorsDimmed { return dim }
        switch role {
        case .primary: return foreground
        case .dim:     return dim
        case .cyan:    return Self.fixed(red: 0x33, green: 0xCB, blue: 0xCC)
        case .yellow:  return Self.fixed(red: 0xE3, green: 0xB3, blue: 0x41)
        case .green:   return Self.fixed(red: 0x6E, green: 0xC2, blue: 0x4D)
        case .magenta: return Self.fixed(red: 0xC8, green: 0x70, blue: 0xE5)
        case .red:     return Self.fixed(red: 0xE5, green: 0x6F, blue: 0x6F)
        case .blue:    return Self.fixed(red: 0x7D, green: 0xA9, blue: 0xCC)
        case .claude:  return Self.fixed(red: 0xE7, green: 0x8C, blue: 0x4D)
        }
    }

    /// Resolve a ``TextStyle`` to its foreground + background rendering
    /// pair. Single source of truth for inline-row rendering. All
    /// styles share the same ``expandedBackground`` gray bg textbox so
    /// every text section reads as one consistent contained block;
    /// only the foreground varies per style.
    public func colors(for style: TextStyle) -> (foreground: Color, background: Color) {
        switch style {
        case .normal, .thinking, .codeMonospace:
            return (primary.opacity(0.85), expandedBackground)
        case .error:
            return (red, expandedBackground)
        }
    }
}
