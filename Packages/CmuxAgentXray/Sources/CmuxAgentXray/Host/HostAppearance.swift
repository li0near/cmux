public import AppKit

/// Pure value snapshot of host-supplied appearance tokens. Replaces the
/// cmux-app-specific `PanelAppearance` type at the package boundary.
///
/// The panel and view layer take this struct rather than reading from
/// AppKit appearance directly so unit tests can stand up arbitrary
/// palettes without instantiating a real `NSApp`.
public struct HostAppearance: Equatable, Sendable {
    /// Foreground "ink" color (terminal-style monospaced text).
    public let foregroundColor: NSColor
    /// Panel background color.
    public let contentBackgroundColor: NSColor

    public init(
        foregroundColor: NSColor,
        contentBackgroundColor: NSColor
    ) {
        self.foregroundColor = foregroundColor
        self.contentBackgroundColor = contentBackgroundColor
    }

    /// Default fallback used by previews / detail tabs that don't carry
    /// a host palette. Mirrors the panel's terminal-dark default.
    public static let defaultDark = HostAppearance(
        foregroundColor: NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
        contentBackgroundColor: NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    )
}
