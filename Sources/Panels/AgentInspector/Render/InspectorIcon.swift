import Foundation

/// SF Symbol mapping for the inspector's per-action icons. Mirrors
/// claude-devtools' Lucide icon vocabulary (Brain for thinking, Wrench for
/// tools, etc.) but adds finer-grained per-tool icons since the SF Symbols
/// catalog supports them and macOS users expect them.
///
/// Each entry has a `collapsed` and an `expanded` variant. The expanded form
/// is typically the `.fill` SF Symbol where one exists, giving users a small
/// state-indicator cue without needing a separate disclosure chevron. Icons
/// without `.fill` siblings reuse the same name; the appearing body below
/// the row is the primary expansion affordance.
enum InspectorIcon {
    struct Pair {
        let collapsed: String
        let expanded: String
    }

    static let user = Pair(collapsed: "person", expanded: "person.fill")
    static let system = Pair(collapsed: "terminal", expanded: "terminal.fill")
    static let thinking = Pair(collapsed: "brain", expanded: "brain.fill")
    static let compact = Pair(collapsed: "square.3.stack.3d", expanded: "square.3.stack.3d")
    /// AI / Claude chunk header. Microbe glyph (claude-as-agent metaphor)
    /// renders through `Image(systemName:)` so it aligns vertically with the
    /// user/system/thinking icons in a row.
    static let ai = Pair(collapsed: "microbe", expanded: "microbe.fill")

    // MARK: - Phase B MetaChunk icons

    /// `↳ Rewind #N` divergence-point row, opens the abandoned branch in
    /// a detail tab. Tree-branch glyph reads as "an alternate path was
    /// taken here" without ambiguity.
    static let branchLink = Pair(collapsed: "arrow.triangle.branch", expanded: "arrow.triangle.branch")
    /// `system.subtype: away_summary` (recap) — Claude returned and
    /// summarised what was happening. Clock-with-circular-arrow reads
    /// as "session resumed, with context recall."
    static let recap = Pair(collapsed: "clock.arrow.circlepath", expanded: "clock.arrow.circlepath")
    /// `pr-link` — PR opened from the session.
    static let prLink = Pair(collapsed: "arrow.up.forward.square", expanded: "arrow.up.forward.square.fill")
    /// Slash-command input pill (the user-typed `/foo args` invocation).
    /// Distinct from `system` (which uses `terminal`) and from `Bash` tool
    /// (which uses `apple.terminal`).
    static let slashCommand = Pair(collapsed: "command.square", expanded: "command.square.fill")
    /// Hook-related rows (`stop_hook_summary`, future `PreToolUse` /
    /// `PostToolUse` / `SessionStart` / `PreCompact`).
    static let hook = Pair(collapsed: "link.badge.plus", expanded: "link.badge.plus")
    /// Skill invocation title row.
    static let skill = Pair(collapsed: "wand.and.sparkles", expanded: "wand.and.sparkles.inverse")
    /// `<system-reminder>` body row.
    static let systemReminder = Pair(collapsed: "bell.badge", expanded: "bell.badge.fill")
    /// `## Context Usage` telemetry block + generic informational rows.
    static let info = Pair(collapsed: "info.circle", expanded: "info.circle.fill")
    /// `system.subtype: api_error` row.
    static let apiError = Pair(collapsed: "exclamationmark.triangle", expanded: "exclamationmark.triangle.fill")
    /// `Continue from where you left off.` resume marker badge.
    static let continueResume = Pair(collapsed: "arrow.uturn.right.circle", expanded: "arrow.uturn.right.circle.fill")

    /// Resolve the icon for a tool by its name. Falls back to the generic
    /// wrench when no specific match is found.
    static func tool(named name: String) -> Pair {
        switch name {
        case "Read":
            return Pair(collapsed: "doc.text", expanded: "doc.text.fill")
        case "Write":
            return Pair(collapsed: "pencil.tip.crop.circle", expanded: "pencil.tip.crop.circle.fill")
        case "Edit", "MultiEdit":
            return Pair(collapsed: "pencil.tip.crop.circle", expanded: "pencil.tip.crop.circle.fill")
        case "Bash":
            return Pair(collapsed: "apple.terminal", expanded: "apple.terminal.fill")
        case "Grep":
            return Pair(collapsed: "magnifyingglass.circle", expanded: "magnifyingglass.circle.fill")
        case "Glob":
            return Pair(collapsed: "doc.text.magnifyingglass", expanded: "doc.text.magnifyingglass")
        case "Task":
            return Pair(collapsed: "person.2", expanded: "person.2.fill")
        case "WebFetch":
            return Pair(collapsed: "arrow.down.doc", expanded: "arrow.down.doc.fill")
        case "WebSearch":
            return Pair(collapsed: "globe.americas", expanded: "globe.americas.fill")
        case "TodoWrite":
            return Pair(collapsed: "list.bullet.clipboard", expanded: "list.bullet.clipboard.fill")
        case "LS":
            return Pair(collapsed: "folder", expanded: "folder.fill")
        case "NotebookEdit":
            return Pair(collapsed: "note.text", expanded: "note.text")
        case "ExitPlanMode":
            return Pair(collapsed: "checkmark.seal", expanded: "checkmark.seal.fill")
        case "AskUserQuestion":
            return Pair(collapsed: "questionmark.bubble", expanded: "questionmark.bubble.fill")
        default:
            return Pair(collapsed: "wrench.adjustable", expanded: "wrench.adjustable.fill")
        }
    }
}

extension InspectorIcon.Pair {
    func systemName(expanded: Bool) -> String {
        expanded ? self.expanded : self.collapsed
    }
}
