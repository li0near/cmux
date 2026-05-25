import Foundation

/// Routing decision for one `ClaudeJSONLLine`. Single source of truth for
/// "what should the chunk builder do with this line"; replaces the
/// scattered `switch line.type` checks that previously littered
/// `ClaudeChunkBuilder.classify()`.
enum ClaudeLineRouting: Equatable {
    /// Drop the line entirely. Either it is session-orphan metadata that
    /// has no place in the chunk list (`permission-mode`, `agent-name`,
    /// `custom-title`, `queue-operation`, `file-history-snapshot`,
    /// `last-prompt`), or telemetry the builder consumes elsewhere
    /// (`system.subtype: turn_duration` is read for per-turn duration
    /// stamping but never rendered as its own chunk).
    case skip

    /// Tree-affiliated line whose UUID is **not** on the active branch.
    /// Builder collects these by parent chain to emit `BranchLink`
    /// chunks at divergence points; individual lines do not render
    /// in the main list.
    case skipBranchAffiliated

    /// Sidechain (sub-agent) message. Builder collects these into a
    /// `[parentToolUseID: [AgentChunk]]` map keyed by their `Task` tool's
    /// `tool_use_id`; the parent Task's `AgentToolCall.sidechainTranscript`
    /// surfaces them via the `↳ Sub-agent` detail-tab link.
    case sidechainMain

    /// Render as one of the standard core chunk kinds.
    case render(ClaudeRenderKind)

    /// Render as a specialised chunk kind introduced for full JSONL
    /// correctness coverage.
    case renderSpecial(ClaudeSpecialKind)
}

/// Core renderable destinations — match the four pre-existing chunk
/// variants on `AgentChunk` (user / ai / system / compact).
enum ClaudeRenderKind: Equatable {
    case user
    case ai
    case system
    case compact
}

/// Specialised renderable destinations introduced in this refactor.
/// Each maps to a `MetaChunk` case (Phase A.6).
enum ClaudeSpecialKind: Equatable {
    case recap                // system.subtype: away_summary
    case prLink               // pr-link line
    case continueResume       // isMeta=true user line, "Continue from where you left off."
    case slashCmdInput        // <command-name> / <command-message> wrapper
    case slashCmdOutput       // <local-command-stdout> / <local-command-stderr>
    case localCommandCaveat   // <local-command-caveat>
    case systemReminder       // <system-reminder>
    case skillTitle           // "Base directory for this skill: …"
    case contextUsage         // "## Context Usage"
    case unknownMeta          // isMeta=true user line that doesn't match any tag
}

enum ClaudeRenderPolicy {
    /// Decide what to do with `line`. `activeBranch` is the set of UUIDs
    /// returned by `ClaudeBranchResolver.resolve(...)`; pass an empty set
    /// if branch resolution is not applicable (no `last-prompt` markers).
    static func route(
        _ line: ClaudeJSONLLine,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool
    ) -> ClaudeLineRouting {
        // Session-orphan metadata + builder-consumed telemetry — always skip.
        if line.isSessionOrphanMetadata { return .skip }
        if line.isLastPromptMarker { return .skip }
        if line.type == "progress" { return .skip }      // sub-agent hook telemetry
        if line.type == "pr-link" { return .renderSpecial(.prLink) }

        // System-line subtype routing.
        if line.type == "system" {
            switch line.subtype ?? "" {
            case "turn_duration":
                return .skip    // consumed for AIChunk per-turn-duration stamp
            case "away_summary":
                return branchGated(line, kind: .renderSpecial(.recap),
                                   activeBranch: activeBranch,
                                   activeBranchAvailable: activeBranchAvailable)
            case "compact_boundary":
                return branchGated(line, kind: .render(.compact),
                                   activeBranch: activeBranch,
                                   activeBranchAvailable: activeBranchAvailable)
            case "api_error", "stop_hook_summary", "local_command", "informational":
                return branchGated(line, kind: .render(.system),
                                   activeBranch: activeBranch,
                                   activeBranchAvailable: activeBranchAvailable)
            default:
                // Unknown subtype: treat as system body. Forward-compatible.
                return branchGated(line, kind: .render(.system),
                                   activeBranch: activeBranch,
                                   activeBranchAvailable: activeBranchAvailable)
            }
        }

        // Sidechain: every sub-agent line gets routed to sidechain pool
        // regardless of branch (sidechains hang off a Task tool that
        // itself is on the active branch).
        if line.isSidechain == true {
            return .sidechainMain
        }

        // User / assistant / attachment — branch-affiliated.
        switch line.type {
        case "user":
            // Compact summary user lines (older flow) → CompactChunk.
            if line.isCompactSummary == true {
                return branchGated(line, kind: .render(.compact),
                                   activeBranch: activeBranch,
                                   activeBranchAvailable: activeBranchAvailable)
            }
            // isMeta=true user lines route by content classification.
            if line.isMeta == true {
                return branchGated(
                    line,
                    kind: routingForMetaUser(line),
                    activeBranch: activeBranch,
                    activeBranchAvailable: activeBranchAvailable
                )
            }
            return branchGated(line, kind: .render(.user),
                               activeBranch: activeBranch,
                               activeBranchAvailable: activeBranchAvailable)
        case "assistant":
            return branchGated(line, kind: .render(.ai),
                               activeBranch: activeBranch,
                               activeBranchAvailable: activeBranchAvailable)
        case "attachment":
            // Attachments are folded under their parent user line; treat
            // as user for branch-gating purposes — the attachment is
            // rendered iff its parent user line would render.
            return branchGated(line, kind: .render(.user),
                               activeBranch: activeBranch,
                               activeBranchAvailable: activeBranchAvailable)
        default:
            // Unknown type: skip rather than crash. Forward-compatible.
            return .skip
        }
    }

    // MARK: - Internal

    /// Apply the active-branch filter when applicable. If the line's UUID
    /// is on the active branch (or branch resolution was not performed),
    /// return the requested routing. Otherwise downgrade to
    /// `skipBranchAffiliated` so the builder collects it for branch links.
    private static func branchGated(
        _ line: ClaudeJSONLLine,
        kind: ClaudeLineRouting,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool
    ) -> ClaudeLineRouting {
        if !activeBranchAvailable { return kind }
        guard let uuid = line.uuid else { return kind }
        return activeBranch.contains(uuid) ? kind : .skipBranchAffiliated
    }

    /// Decide the routing for an `isMeta=true` user line based on the
    /// classification of its inner text.
    ///
    /// `tool_result` blocks ride on `isMeta=true` user lines too — those
    /// must keep folding into the pending `AIChunk` so the parent tool
    /// call gets its result attached. Only `isMeta=true` lines whose
    /// content is **not** a tool_result envelope route to a `MetaChunk`
    /// surface.
    private static func routingForMetaUser(_ line: ClaudeJSONLLine) -> ClaudeLineRouting {
        if let content = line.message?.content,
           case .blocks(let blocks) = content,
           blocks.contains(where: { $0.type == "tool_result" }) {
            return .render(.ai)
        }
        let raw = extractMetaText(line)
        switch ClaudeContentDetector.classify(raw) {
        case .slashCommandInput:    return .renderSpecial(.slashCmdInput)
        case .slashCommandOutput:   return .renderSpecial(.slashCmdOutput)
        case .systemReminder:       return .renderSpecial(.systemReminder)
        case .skillInvocation:      return .renderSpecial(.skillTitle)
        case .contextUsage:         return .renderSpecial(.contextUsage)
        // Resume markers and command-caveat wrappers carry no
        // user-actionable content; the `Continue from where you left
        // off.` string is auto-injected on session resume and the
        // `<local-command-caveat>` block always wraps a stdout that's
        // already surfaced as `slashCmdOutput`. Drop both.
        case .continueResume:       return .skip
        case .localCommandCaveat:   return .skip
        case .unknown:              return .renderSpecial(.unknownMeta)
        }
    }

    private static func extractMetaText(_ line: ClaudeJSONLLine) -> String {
        guard let content = line.message?.content else { return "" }
        switch content {
        case .text(let s): return s
        case .blocks(let blocks):
            for b in blocks where b.type == "text" {
                if let t = b.text { return t }
            }
            return ""
        }
    }
}
