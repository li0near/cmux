import Foundation

/// Per-type parser for `type: "attachment"` JSONL lines.
///
/// Branches on `attachment.type`. Most attachment subtypes are
/// session-state telemetry the user doesn't need to see — explicit
/// `.skip`.
///
/// `queued_command` is the exception: it carries `attachment.prompt`,
/// the text the user typed while the assistant was mid-turn. Without
/// surfacing it, two `AgentEntry`s appear back-to-back with no
/// `UserEntry` between them, breaking Claude's user/assistant
/// alternation invariant. The plan-mode family + `edited_text_file`
/// are also user-visible session events.
enum AttachmentLineDispatcher {
    static func parse(_ line: ClaudeJSONLLine) -> ClaudeLineRouting {
        switch line.attachment?.type {
        case "queued_command":
            // Skip harness-emitted background-task completion echoes;
            // they're not user prompts. Older sessions have no
            // `commandMode` and still render. See AttachmentParserTests.
            if line.attachment?.commandMode == "task-notification" {
                return .skip
            }
            return .renderSpecial(.queuedPrompt)
        case "plan_mode":
            return .renderSpecial(.planModeEntered)
        case "plan_mode_exit":
            return .renderSpecial(.planModeExited)
        case "plan_mode_reentry":
            return .renderSpecial(.planModeReentered)
        case "edited_text_file":
            return .renderSpecial(.editedTextFile)
        default:
            return .skip
        }
    }
}
