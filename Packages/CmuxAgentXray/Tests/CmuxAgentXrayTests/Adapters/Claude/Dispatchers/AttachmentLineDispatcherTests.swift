import Foundation
import Testing
@testable import CmuxAgentXray

/// `attachment.queued_command` lines arrive in two flavors discriminated
/// by `commandMode`:
///
/// - `"prompt"` — the user typed text mid-AI-turn; render as a user
///   message bubble.
/// - `"task-notification"` — the harness echoes a background-task
///   completion (`Bash(run_in_background: true)` + later
///   `<task-notification>...</task-notification>` envelope); not a user
///   prompt and must NOT render as one.
///
/// Older sessions emit `queued_command` without `commandMode` at all;
/// those still render. The discriminator is a blacklist, not an
/// allowlist.
@Suite("AttachmentLineDispatcher — queued_command commandMode routing")
struct AttachmentLineDispatcherTests {

    private func decodeLine(_ json: String) throws -> ClaudeJSONLLine {
        try AgentXrayJSON.decoder.decode(
            ClaudeJSONLLine.self,
            from: Data(json.utf8)
        )
    }

    @Test("commandMode 'prompt' renders as queued user prompt")
    func promptRouting() throws {
        let line = try decodeLine(#"""
        {
          "type": "attachment",
          "uuid": "u-1",
          "attachment": {
            "type": "queued_command",
            "prompt": "hello",
            "commandMode": "prompt"
          }
        }
        """#)
        let routing = AttachmentLineDispatcher.parse(line)
        #expect(routing == .renderSpecial(.queuedPrompt))
    }

    @Test("commandMode missing (legacy) renders as queued user prompt")
    func legacyMissingCommandMode() throws {
        let line = try decodeLine(#"""
        {
          "type": "attachment",
          "uuid": "u-3",
          "attachment": {
            "type": "queued_command",
            "prompt": "legacy prompt"
          }
        }
        """#)
        let routing = AttachmentLineDispatcher.parse(line)
        #expect(routing == .renderSpecial(.queuedPrompt))
    }

    @Test("commandMode 'task-notification' is a harness echo and must be skipped")
    func taskNotificationRouting() throws {
        let line = try decodeLine(#"""
        {
          "type": "attachment",
          "uuid": "u-2",
          "attachment": {
            "type": "queued_command",
            "prompt": "<task-notification><task-id>x</task-id></task-notification>",
            "commandMode": "task-notification"
          }
        }
        """#)
        let routing = AttachmentLineDispatcher.parse(line)
        #expect(routing == .skip)
    }
}
