/// Abstract palette role used to express "what kind of accent color
/// this should be" without committing to a concrete SwiftUI `Color`.
///
/// Lives in the Views layer next to ``HudPalette`` because color
/// resolution is a view-layer concern. Two concrete consumers share the
/// same enum:
/// - ``EntryView`` (live transcript rows) — `kindAccentColor` reads
///   `PaletteRole.forEntry(entry)?.color(in: palette)`.
/// - ``DetailContent`` (detail-mode header) — carries `accent: PaletteRole`
///   set by the resolver per-arm; the detail view resolves via
///   `palette.color(for: content.accent)`.
///
/// Adding a new role: add the case here, extend ``HudPalette/color(for:)``
/// to map it, and update the relevant dispatch (``forEntry(_:)`` for
/// live-row use; the resolver arms in `DetailContent.swift` for
/// detail-header use).
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

extension PaletteRole {
    /// Per–top-level-Entry accent dispatch. Mirrors the rules originally
    /// inlined in `EntryView.kindAccentColor` so live-row coloring and
    /// detail-mode coloring share one source of truth.
    ///
    /// Returns nil when the entry has no kind-specific accent (renderer
    /// falls back to `palette.primary`).
    public static func forEntry(_ entry: Entry) -> PaletteRole? {
        switch entry {
        case .user:
            return .blue
        case .agent:
            return .claude
        case .system(let sys):
            switch sys.subType {
            case .systemReminder:
                return .yellow
            case .contextUsage:
                return .dim
            case .localCommand,
                 .slashCmdInput,
                 .slashCmdOutput,
                 .skill,
                 .recap,
                 .planMode,
                 .editedTextFile,
                 .other:
                return .cyan
            }
        case .compact:
            return .dim
        case .synthesized(let syn):
            switch syn.kind {
            case .branchLink: return .dim
            case .prLink:     return .blue
            }
        case .text, .tool:
            // Sub-entry-only cases — never appear at top level. Renderer
            // falls back to palette.primary.
            return nil
        }
    }
}
