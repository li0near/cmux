import Foundation

/// Routing decision for one `ClaudeJSONLLine`. Single source of truth for
/// "what should the transcript builder do with this line."
enum ClaudeLineRouting: Equatable {
    /// Drop the line entirely — session-orphan metadata, or telemetry
    /// that the builder consumes elsewhere (`turn_duration` is read for
    /// per-turn duration stamping but never rendered as its own entry).
    case skip

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
    /// `<command-name>` / `<command-message>` wrapper. Payload is the
    /// parsed (name, args) pre-extracted by the dispatcher so the
    /// builder doesn't re-classify the same body.
    case slashCmdInput(name: String, args: String?)
    /// `<local-command-stdout>` / `<local-command-stderr>` wrapper.
    /// Payload is the inner body + the stream discriminator.
    case slashCmdOutput(body: String, isStderr: Bool)
    case localCommandCaveat   // <local-command-caveat>
    /// `<system-reminder>` wrapper. Payload is the inner body.
    case systemReminder(body: String)
    /// `"Base directory for this skill: …"` wrapper. Payload is the
    /// skill name + (optional) base path + body.
    case skill(name: String, basePath: String?, body: String)
    /// `"## Context Usage"` wrapper. Payload is the inner body.
    case contextUsage(body: String)
    case unknownMeta          // isMeta=true user line that doesn't match any tag
    case queuedPrompt         // attachment.type=queued_command
    case planModeEntered      // attachment.type=plan_mode
    case planModeExited       // attachment.type=plan_mode_exit
    case planModeReentered    // attachment.type=plan_mode_reentry
    case editedTextFile       // attachment.type=edited_text_file
}

/// Top-level dispatcher. Per-type branching lives in
/// `Adapters/Claude/Parsers/<Type>LineParser.swift`; this file is just
/// the entry-point switch.
///
/// Dispatch order:
///   1. `CommonLineDispatcher` claims session-orphan metadata + `pr-link`.
///   2. Sidechain check — `isSidechain: true` → sub-agent pool.
///   3. Per-`type` parser.
///   4. Unknown `type` — log in DEBUG, route to `.skip`.
///
/// Post-G4 the active-branch filter is gone — `ClaudeTranscriptBuilder`
/// detects rewinds inline at user-prompt arrival and slices the
/// abandoned tail into a synthesized branch link via
/// `Transcript.branchOff`. Pre-G4 routes that returned
/// `.skipBranchAffiliated` no longer have a routing case.
enum ClaudeLineDispatcher {
    static func route(
        _ line: ClaudeJSONLLine,
        logger: any AgentXrayLogger = NoOpAgentXrayLogger()
    ) -> ClaudeLineRouting {
        if let routing = CommonLineDispatcher.parse(line) { return routing }

        if line.isSidechain == true {
            return .sidechainMain
        }

        switch line.type {
        case "user":
            return UserLineDispatcher.parse(line)
        case "assistant":
            return AssistantLineDispatcher.parse(line)
        case "system":
            return SystemLineDispatcher.parse(line)
        case "attachment":
            return AttachmentLineDispatcher.parse(line)
        default:
            logger.warning("Claude JSONL: unknown line type '\(line.type)'")
            return .skip
        }
    }
}
