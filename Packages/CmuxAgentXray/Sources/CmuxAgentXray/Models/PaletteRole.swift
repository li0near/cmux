/// Abstract palette role used by Models/Panel-layer types to express
/// "what kind of accent color this should be" without depending on
/// SwiftUI. The view layer resolves a `PaletteRole` against a concrete
/// ``HudPalette`` via `HudPalette.color(for:)`.
///
/// Lives in Models because it's a pure value type referenced from
/// ``DetailContent`` (Panel layer); putting it here keeps the
/// SwiftUI-free seam intact.
public enum PaletteRole: Equatable, Sendable {
    /// Default foreground (terminal text color).
    case primary
    /// Soft / secondary text (55% of `primary`).
    case dim
    case cyan
    case yellow
    case green
    case magenta
    case red
    case blue
    /// Claude's signature orange.
    case claude
}
