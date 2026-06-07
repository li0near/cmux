import Foundation

/// Per-type parser for `type: "system"` JSONL lines.
///
/// Branches on `subtype`. Recognised subtypes route to dedicated
/// renderable surfaces (`recap`, `compact`); generic `system`-bodied
/// subtypes and unknown future subtypes fall through to the catch-all
/// System entry so they never silently disappear.
///
/// `turn_duration` is a special case: the line is consumed by
/// `ClaudeTurnDurationResolver` for `AgentEntry` header stamping; no
/// entry is emitted.
enum SystemLineDispatcher {
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
            // slashCmdOutput meta — payload pre-extracted via
            // `ClaudeContentDetector` so the builder doesn't re-classify.
            let body = (line.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch ClaudeContentDetector.classify(body) {
            case .slashCommandInput(let name, let args):
                return ClaudeLineDispatcher.branchGated(
                    line, kind: .renderSpecial(.slashCmdInput(name: name, args: args)),
                    activeBranch: activeBranch,
                    activeBranchAvailable: activeBranchAvailable
                )
            case .slashCommandOutput(let body, let isStderr):
                return ClaudeLineDispatcher.branchGated(
                    line, kind: .renderSpecial(.slashCmdOutput(body: body, isStderr: isStderr)),
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
