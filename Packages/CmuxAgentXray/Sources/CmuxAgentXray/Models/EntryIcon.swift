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
    /// Agent turn (Claude / Codex).
    public static let agent = EntryIcon(collapsed: "microbe", expanded: "microbe.fill")
    /// System line (local-command output, generic).
    public static let system = EntryIcon(collapsed: "terminal")
    /// Compact-summary entry.
    public static let compact = EntryIcon(collapsed: "doc.text.below.ecg")
    /// Thinking sub-entry.
    public static let thinking = EntryIcon(collapsed: "brain")
    /// Slash-command line.
    public static let slashCommand = EntryIcon(collapsed: "chevron.left.forwardslash.chevron.right")
    /// Skill invocation.
    public static let skill = EntryIcon(collapsed: "wand.and.stars")
    /// `<system-reminder>` body.
    public static let systemReminder = EntryIcon(collapsed: "exclamationmark.bubble")
    /// `## Context Usage` recap.
    public static let contextInfo = EntryIcon(collapsed: "info.circle")
    /// `away_summary` recap.
    public static let recap = EntryIcon(collapsed: "text.book.closed")
    /// Plan-mode marker.
    public static let planMode = EntryIcon(collapsed: "list.bullet.clipboard")
    /// External text-file edit.
    public static let editedTextFile = EntryIcon(collapsed: "pencil.and.outline")
    /// API-error synthetic line (currently dropped, reserved).
    public static let apiError = EntryIcon(collapsed: "exclamationmark.octagon")
    /// Continue/resume marker.
    public static let continueResume = EntryIcon(collapsed: "arrow.uturn.right.circle")
    /// Branch-link synthesizer row.
    public static let branchLink = EntryIcon(collapsed: "arrow.triangle.branch")
    /// External PR link.
    public static let prLink = EntryIcon(collapsed: "arrow.up.right.square")
}

// MARK: - Tool icon dispatch

extension EntryIcon {
    /// Map a tool name (as reported by the agent) to its SF Symbol pair.
    /// Falls back to a generic wrench glyph for unknown tools.
    public static func tool(named name: String) -> EntryIcon {
        switch name {
        case "Read":           return EntryIcon(collapsed: "doc.text")
        case "Write":          return EntryIcon(collapsed: "square.and.pencil")
        case "Edit":           return EntryIcon(collapsed: "pencil.line")
        case "Bash":           return EntryIcon(collapsed: "terminal")
        case "Grep", "Glob":   return EntryIcon(collapsed: "magnifyingglass")
        case "WebFetch", "WebSearch":
            return EntryIcon(collapsed: "globe")
        case "Task", "Agent":  return EntryIcon(collapsed: "person.2")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList":
            return EntryIcon(collapsed: "checklist")
        case "NotebookEdit":   return EntryIcon(collapsed: "book.closed")
        default:               return EntryIcon(collapsed: "wrench.and.screwdriver")
        }
    }
}
