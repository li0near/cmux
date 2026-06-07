import Foundation

/// `attachment` line payload. Decoded from any
/// `type: "attachment"` JSONL line.
struct ClaudeAttachment: Decodable, Equatable {
    /// Discriminator: `queued_command`, `plan_mode`, `plan_mode_exit`,
    /// `plan_mode_reentry`, `edited_text_file`, `hook_success`,
    /// `task_reminder`, `diagnostics`, `skill_listing`,
    /// `deferred_tools_delta`, `command_permissions`, `date_change`,
    /// `hook_non_blocking_error`.
    let type: String?
    /// `queued_command` — the queued user prompt text.
    let prompt: ClaudeMessageContent?
    /// `edited_text_file` — absolute filename.
    let filename: String?
    /// `edited_text_file` — file content snippet at edit time.
    let snippet: String?
    /// `plan_mode` family — path of the plan file.
    let planFilePath: String?
    /// `plan_mode` family — whether the plan file already exists on disk.
    let planExists: Bool?
    /// `plan_mode` only — `"full"` / `"reentry"` etc.
    let reminderType: String?
    /// `queued_command` only — origin discriminator.
    /// `"prompt"` = user typed mid-AI-turn (render as user message).
    /// `"task-notification"` = harness echo of a background-task
    /// completion (`Bash(run_in_background: true)`); skip.
    /// nil on older sessions; treat as `"prompt"`.
    let commandMode: String?
}
