/// Pair of SF Symbol names representing an entry's role icon — one for
/// the collapsed state, one for expanded. Pure data; the view layer
/// translates `systemName(expanded:)` into a SwiftUI `Image`.
///
/// Lives in Models because `Header.icon` references it. Adding a new
/// canonical icon (or registering a tool icon) is a Models-layer concern,
/// not a Views-layer one.
public struct EntryIcon: Equatable, Sendable, Hashable {
    public let collapsed: String
    public let expanded: String

    public init(collapsed: String, expanded: String? = nil) {
        self.collapsed = collapsed
        self.expanded = expanded ?? collapsed
    }

    /// Resolve to the right SF Symbol name for the current expansion
    /// state. Most icons return `collapsed` regardless of expansion;
    /// chevron-style icons return distinct collapsed/expanded names.
    public func systemName(expanded isExpanded: Bool) -> String {
        isExpanded ? expanded : collapsed
    }
}

// MARK: - Canonical role icons

extension EntryIcon {
    /// Generic user prompt.
    public static let user = EntryIcon(collapsed: "person", expanded: "person.fill")
    /// Queued user prompt — pulses while pending.
    public static let queuedUser = EntryIcon(
        collapsed: "person.badge.plus",
        expanded: "person.badge.plus.fill"
    )
    /// Agent entry header (Claude / Codex).
    public static let agent = EntryIcon(collapsed: "microbe", expanded: "microbe.fill")
    /// Thinking sub-entry.
    public static let thinking = EntryIcon(collapsed: "brain", expanded: "brain.fill")
    /// System line (local-command output, generic).
    public static let system = EntryIcon(collapsed: "terminal", expanded: "terminal.fill")
    /// Compact-summary entry. Same glyph collapsed/expanded.
    public static let compact = EntryIcon(collapsed: "square.stack.3d.up", expanded: "square.stack.3d.up.fill")
    /// Slash-command line.
    public static let slashCommand = EntryIcon(collapsed: "command.square", expanded: "command.square.fill")
    /// Skill invocation.
    public static let skill = EntryIcon(
        collapsed: "wand.and.sparkles",
        expanded: "wand.and.sparkles.inverse"
    )
    /// `<system-reminder>` body.
    public static let systemReminder = EntryIcon(
        collapsed: "bell.badge",
        expanded: "bell.badge.fill"
    )
    /// `## Context Usage` recap.
    public static let contextInfo = EntryIcon(
        collapsed: "info.circle",
        expanded: "info.circle.fill"
    )
    /// `away_summary` recap. Same glyph collapsed/expanded.
    public static let recap = EntryIcon(collapsed: "clock", expanded: "clock.fill")
    /// Plan-mode marker.
    public static let planMode = EntryIcon(
        collapsed: "list.bullet.rectangle",
        expanded: "list.bullet.rectangle.fill"
    )
    /// External text-file edit. Same glyph collapsed/expanded.
    public static let editedTextFile = EntryIcon(collapsed: "pencil.line")
    /// Branch-link synthesizer entry — reuses the `arrow.triangle.branch`
    /// glyph for both rewind toggle and branch links.
    public static let branchLink = EntryIcon(collapsed: "arrow.triangle.branch")
    /// External PR link.
    public static let prLink = EntryIcon(
        collapsed: "arrow.up.forward.square",
        expanded: "arrow.up.forward.square.fill"
    )
}

// MARK: - Tool icon dispatch

extension EntryIcon {
    /// Map a tool name (as reported by the agent) to its SF Symbol pair.
    /// Falls back to a generic adjustable-wrench glyph for unknown tools.
    public static func tool(named name: String) -> EntryIcon {
        switch name {
        case "Read":
            return EntryIcon(collapsed: "doc.text", expanded: "doc.text.fill")
        case "Write", "Edit", "MultiEdit":
            return EntryIcon(
                collapsed: "pencil.tip.crop.circle",
                expanded: "pencil.tip.crop.circle.fill"
            )
        case "Bash":
            return EntryIcon(collapsed: "apple.terminal", expanded: "apple.terminal.fill")
        case "Grep":
            return EntryIcon(
                collapsed: "magnifyingglass.circle",
                expanded: "magnifyingglass.circle.fill"
            )
        case "Glob":
            return EntryIcon(collapsed: "doc.text.magnifyingglass")
        case "WebFetch":
            return EntryIcon(collapsed: "arrow.down.doc", expanded: "arrow.down.doc.fill")
        case "WebSearch":
            return EntryIcon(collapsed: "globe.americas", expanded: "globe.americas.fill")
        case "Task", "Agent":
            return EntryIcon(collapsed: "person.2", expanded: "person.2.fill")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList":
            return EntryIcon(
                collapsed: "list.bullet.clipboard",
                expanded: "list.bullet.clipboard.fill"
            )
        case "NotebookEdit":
            return EntryIcon(collapsed: "note.text")
        case "LS":
            return EntryIcon(collapsed: "folder", expanded: "folder.fill")
        case "ExitPlanMode":
            return EntryIcon(collapsed: "checkmark.seal", expanded: "checkmark.seal.fill")
        case "AskUserQuestion":
            return EntryIcon(
                collapsed: "questionmark.bubble",
                expanded: "questionmark.bubble.fill"
            )
        default:
            return EntryIcon(
                collapsed: "wrench.adjustable",
                expanded: "wrench.adjustable.fill"
            )
        }
    }
}
