import Foundation

/// Per-type parser for `type: "attachment"` JSONL lines.
///
/// Branches on `attachment.type`. Most attachment subtypes are
/// session-state telemetry the user doesn't need to see — explicit
/// `.skip`.
///
/// `queued_command` is the exception: it carries `attachment.prompt`,
/// the text the user typed while the assistant was mid-turn. Without
/// surfacing it, two `AgentTurn`s appear back-to-back with no
/// `UserEntry` between them, breaking Claude's user/assistant
/// alternation invariant. The plan-mode family + `edited_text_file`
/// are also user-visible session events.
enum AttachmentLineParser {
    static func parse(
        _ line: ClaudeJSONLLine,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool
    ) -> ClaudeLineRouting {
        switch line.attachment?.type {
        case "queued_command":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .renderSpecial(.queuedPrompt),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "plan_mode":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .renderSpecial(.planModeEntered),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "plan_mode_exit":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .renderSpecial(.planModeExited),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "plan_mode_reentry":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .renderSpecial(.planModeReentered),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        case "edited_text_file":
            return ClaudeLineDispatcher.branchGated(
                line, kind: .renderSpecial(.editedTextFile),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        default:
            return .skip
        }
    }
}
