import Foundation

/// Routing decision for one `ClaudeJSONLLine`. Single source of truth for
/// "what should the transcript builder do with this line."
enum ClaudeLineRouting: Equatable {
    /// Drop the line entirely — session-orphan metadata, or telemetry
    /// that the builder consumes elsewhere (`turn_duration` is read for
    /// per-turn duration stamping but never rendered as its own entry).
    case skip

    /// Tree-affiliated line whose UUID is **not** on the active branch.
    /// Builder collects these by parent chain to emit branch-link
    /// entries at divergence points; individual lines do not render in
    /// the main list.
    case skipBranchAffiliated

    /// Sidechain (sub-agent) message. Builder collects these into a
    /// `[parentToolUseID: [Entry]]` map keyed by their `Task` tool's
    /// `tool_use_id`; the parent Task's sidechain transcript surfaces
    /// them via the detail-tab link.
    case sidechainMain

    /// Render as one of the standard core entry kinds.
    case render(ClaudeRenderKind)

    /// Render as a specialised entry kind.
    case renderSpecial(ClaudeSpecialKind)
}

/// Core renderable destinations — match the four pre-existing top-level
/// `Entry` cases (user / agent / system / compact).
enum ClaudeRenderKind: Equatable {
    case user
    case agent
    case system
    case compact
}

/// Specialised renderable destinations. Each routes through
/// `ClaudeTranscriptBuilder` to a `SystemEntry` (with the matching
/// `SystemEntry.SubType`) or a `SynthesizedEntry`.
enum ClaudeSpecialKind: Equatable {
    case recap                // system.subtype: away_summary
    case prLink               // pr-link line
    case continueResume       // isMeta=true user line, "Continue from where you left off."
    case slashCmdInput        // <command-name> / <command-message> wrapper
    case slashCmdOutput       // <local-command-stdout> / <local-command-stderr>
    case localCommandCaveat   // <local-command-caveat>
    case systemReminder       // <system-reminder>
    case skill                // "Base directory for this skill: …"
    case contextUsage         // "## Context Usage"
    case unknownMeta          // isMeta=true user line that doesn't match any tag
    case queuedPrompt         // attachment.type=queued_command
    case planModeEntered      // attachment.type=plan_mode
    case planModeExited       // attachment.type=plan_mode_exit
    case planModeReentered    // attachment.type=plan_mode_reentry
    case editedTextFile       // attachment.type=edited_text_file
}

/// Top-level dispatcher. Per-type branching lives in
/// `Adapters/Claude/Parsers/<Type>LineParser.swift`; this file is just
/// the entry-point switch + the shared `branchGated` helper.
///
/// Dispatch order:
///   1. `CommonLineDispatcher` claims session-orphan metadata + `pr-link`.
///   2. Sidechain check — `isSidechain: true` → sub-agent pool.
///   3. Per-`type` parser.
///   4. Unknown `type` — log in DEBUG, route to `.skip`.
enum ClaudeLineDispatcher {
    static func route(
        _ line: ClaudeJSONLLine,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool,
        skillCommandUuids: Set<String> = [],
        logger: any AgentXrayLogger = NoOpAgentXrayLogger()
    ) -> ClaudeLineRouting {
        if let routing = CommonLineDispatcher.parse(line) { return routing }

        if line.isSidechain == true {
            return .sidechainMain
        }

        switch line.type {
        case "user":
            return UserLineDispatcher.parse(
                line,
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable,
                skillCommandUuids: skillCommandUuids
            )
        case "assistant":
            return AssistantLineDispatcher.parse(
                line,
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "system":
            return SystemLineDispatcher.parse(
                line,
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "attachment":
            return AttachmentLineDispatcher.parse(
                line,
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        default:
            logger.warning("Claude JSONL: unknown line type '\(line.type)'")
            return .skip
        }
    }

    /// Apply the active-branch filter when applicable.
    static func branchGated(
        _ line: ClaudeJSONLLine,
        kind: ClaudeLineRouting,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool
    ) -> ClaudeLineRouting {
        if !activeBranchAvailable { return kind }
        guard let uuid = line.uuid else { return kind }
        return activeBranch.contains(uuid) ? kind : .skipBranchAffiliated
    }
}
