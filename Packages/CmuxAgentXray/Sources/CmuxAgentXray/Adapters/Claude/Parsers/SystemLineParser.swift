import Foundation

/// Per-type parser for `type: "system"` JSONL lines.
///
/// Branches on `subtype`. Recognised subtypes route to dedicated
/// renderable surfaces (`recap`, `compact`); generic `system`-bodied
/// subtypes and unknown future subtypes fall through to the catch-all
/// System entry so they never silently disappear.
///
/// `turn_duration` is a special case: the line is consumed by
/// `ClaudeTurnDurationResolver` for `AgentTurn` header stamping; no
/// entry is emitted.
enum SystemLineParser {
    static func parse(
        _ line: ClaudeJSONLLine,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool
    ) -> ClaudeLineRouting {
        switch line.subtype ?? "" {
        case "turn_duration":
            return .skip
        case "away_summary":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .renderSpecial(.recap),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "compact_boundary":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .render(.compact),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "local_command":
            // Built-in slash commands written via the system-line
            // envelope (`/rename`, `/status`, `/branch`, `/agents`,
            // `/resume`). Input line carries `<command-name>` in the
            // top-level `.content`; output line carries
            // `<local-command-stdout>` (or stderr) and points at the
            // input via `parentUuid`. Pair them as slashCmdInput +
            // slashCmdOutput meta.
            let body = (line.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("<command-name>") || body.hasPrefix("<command-message>") {
                return ClaudeLineDispatcher.branchGated(
                    line, kind: .renderSpecial(.slashCmdInput),
                    activeBranch: activeBranch,
                    activeBranchAvailable: activeBranchAvailable
                )
            }
            if body.hasPrefix("<local-command-stdout>")
                || body.hasPrefix("<local-command-stderr>") {
                return ClaudeLineDispatcher.branchGated(
                    line, kind: .renderSpecial(.slashCmdOutput),
                    activeBranch: activeBranch,
                    activeBranchAvailable: activeBranchAvailable
                )
            }
            return ClaudeLineDispatcher.branchGated(
                line, kind: .render(.system),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "api_error", "stop_hook_summary", "informational":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .render(.system),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        default:
            return ClaudeLineDispatcher.branchGated(
                line, kind: .render(.system),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        }
    }
}
