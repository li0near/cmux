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

    @Test("commandMode 'prompt' renders as queued user prompt")
    func promptRouting() throws {
        let line = try JSONLFixture.line(named: "attachment-queued-command-prompt")
        let routing = AttachmentLineDispatcher.parse(line)
        #expect(routing == .renderSpecial(.queuedPrompt))
    }

    @Test("commandMode missing (legacy) renders as queued user prompt")
    func legacyMissingCommandMode() throws {
        let line = try JSONLFixture.line(named: "attachment-queued-command-legacy")
        let routing = AttachmentLineDispatcher.parse(line)
        #expect(routing == .renderSpecial(.queuedPrompt))
    }

    @Test("commandMode 'task-notification' is a harness echo and must be skipped")
    func taskNotificationRouting() throws {
        let line = try JSONLFixture.line(named: "attachment-queued-command-task-notification")
        let routing = AttachmentLineDispatcher.parse(line)
        #expect(routing == .skip)
    }
}
