public import Foundation

/// Header data for every `Entry`. Replaces the older
/// `name`/`summary`/per-row-icon scatter with one structured value.
///
/// Render contract: the renderer composes the header as a horizontal row:
///
///     [icon]  [name]  [label]  [title]  [trailing items…]  [timestamp]
///
/// Every field is independently optional so any variant can decline a
/// piece (e.g., `name = nil` hides the role label entirely; the agent
/// turn header uses this to drop "Claude" when the model label is shown).
///
/// The header carries display-ready strings only — never localizes,
/// truncates, or formats at render time. Builders pre-localize role
/// labels via `String(localized:bundle:)` and pre-format timestamps
/// via the package's time formatter.
public struct Header: Equatable, Sendable {
    /// Role icon (user / agent / system / tool / etc.).
    public let icon: EntryIcon?
    /// Localized role label ("User", "Claude", "System"). `nil` to hide
    /// the label entirely.
    public let name: String?
    /// Optional model/version pill (e.g. "Opus 4.7"). Rendered as a dim
    /// pill after the name. `nil` hides the pill.
    public let label: String?
    /// Dynamic content title (file path, command name, recap title,
    /// preview text). Rendered after the label, truncated to fit. Never
    /// localized — carries raw content from the JSONL line.
    public let title: String?
    /// Trailing metadata items (status dots, durations, word counts,
    /// custom pills). Rendered right-aligned just before the timestamp.
    public let trailing: [TrailingItem]
    /// Wall-clock timestamp for the entry, when available. Renderer
    /// formats as "HH:MM:SS".
    public let timestamp: Date?

    public init(
        icon: EntryIcon? = nil,
        name: String? = nil,
        label: String? = nil,
        title: String? = nil,
        trailing: [TrailingItem] = [],
        timestamp: Date? = nil
    ) {
        self.icon = icon
        self.name = name
        self.label = label
        self.title = title
        self.trailing = trailing
        self.timestamp = timestamp
    }
}

/// One metadata item rendered in the header's trailing area. Pre-formatted
/// at construction time so the renderer never branches on type at render
/// time beyond the pill style.
public enum TrailingItem: Equatable, Sendable {
    /// Plain text label (no chrome).
    case text(String)
    /// Rounded-rect pill (e.g. "1.2k tokens", "12 words").
    case pill(String)
    /// Three-state colored dot for tool status.
    case statusDot(StatusDotKind)
    /// Pre-formatted duration string (e.g. "4m 33s").
    case duration(String)
    /// Pre-formatted word-count string (e.g. "120 words").
    case wordCount(String)
    /// Tap-to-toggle token-count pill. Renders the compact total
    /// (e.g. "32.9k tokens") by default; clicking flips to the
    /// per-bucket breakdown (e.g. "12.0k in · 1.5k out · 19.4k cr").
    /// Carries the raw counts (via ``AgentEntry/TokenUsage``) so the
    /// renderer can format both states.
    case tokenPill(AgentEntry.TokenUsage)
}

/// Color discriminator for a `statusDot` trailing item. Mirrors
/// claude-devtools' three-state pending / ok / error convention.
public enum StatusDotKind: Equatable, Sendable {
    case pending, ok, error
}
