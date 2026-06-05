public import Foundation

/// JSONL `type: "system"` entry. Covers every system subtype the
/// inspector consumes — local-command output, slash-command pairs, skill
/// invocations, system reminders, context usage telemetry, recap, plan
/// mode, external-edit markers, and a forward-compat escape hatch.
///
/// The renderer dispatches on `subType` to choose icon, accent color,
/// and section layout — but the row's `Header` and `Body` are pre-built
/// at construction time, so the renderer never reaches into `subType`
/// for header content.
public struct SystemEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let header: Header
    public let body: Body
    public let subType: SubType

    public init(
        id: EntryID,
        header: Header,
        body: Body,
        subType: SubType
    ) {
        self.id = id
        self.header = header
        self.body = body
        self.subType = subType
    }

    public var timestamp: Date? { header.timeMarker?.clockDate }

    /// Closed enumeration of every observed JSONL `system.subtype`
    /// flavour, plus a forward-compat `.other(_)` escape hatch. Case
    /// payloads carry the subtype-specific data the renderer needs to
    /// dispatch behaviour beyond the standard header/body layout.
    public enum SubType: Equatable, Sendable {
        /// `<local-command-stdout>` / `<local-command-stderr>` raw payload.
        /// `input` carries the command text the user typed.
        case localCommand(input: String)
        /// `/<commandName> [args]` user input pill.
        case slashCmdInput(name: String, args: String?)
        /// Slash-command stdout/stderr (`isStderr` distinguishes them).
        case slashCmdOutput(isStderr: Bool)
        /// Skill invocation (name + base path metadata).
        case skill(name: String, basePath: String?)
        /// `<system-reminder>` body.
        case systemReminder
        /// `## Context Usage` recap-style telemetry block.
        case contextUsage
        /// `system.subtype: away_summary` — Claude Code's "you returned" recap.
        case recap
        /// Plan-mode entry/exit/re-entry transition row.
        case planMode(phase: PlanModePhase, planFilePath: String?, planExists: Bool)
        /// `attachment.type == "edited_text_file"` — external edit row.
        case editedTextFile(path: String)
        /// Forward-compat: unknown JSONL system subtype. The raw subtype
        /// string is preserved so the renderer can fall back to a
        /// "System: <subtype>" row.
        case other(String)
    }

    /// Phase carried by `SubType.planMode(...)`.
    public enum PlanModePhase: Equatable, Sendable {
        case entered, exited, reentered
    }
}
