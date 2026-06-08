import Foundation

/// In-place mutation that stamps an ``AgentEntry`` with
/// `perTurnDurationMs` and `messageCount` from a
/// `system.subtype: turn_duration` JSONL line.
///
/// **Caller contract.** The dispatcher resolves the line's
/// `parentUuid` to the containing AgentEntry (via the universal alias
/// rule on ``Transcript/index``) and invokes ``Transcript/mutate``
/// with that AgentEntry's id. Heterogeneous parent types in the
/// corpus (assistant 65.7%, system/stop_hook_summary 33.8%,
/// user/tool_result 0.4%) all alias-resolve to the right AgentEntry
/// path uniformly.
///
/// Example:
///
/// ```swift
/// let update = TurnDurationUpdate(durationMs: ms, messageCount: cnt)
/// transcript.mutate(id: agentEntryId) { entry in
///     update.apply(&entry)
/// }
/// ```
struct TurnDurationUpdate {
    /// Total wall-clock duration of the turn in milliseconds, sourced
    /// from Claude's `system.subtype: turn_duration` JSONL entry.
    let durationMs: Int
    /// Total message count for the turn from the same JSONL entry.
    let messageCount: Int

    /// Apply this update to the matching ``AgentEntry`` in place.
    /// No-op if `entry` is not a `.agent` case.
    func apply(_ entry: inout Entry) {
        guard case .agent(var agent) = entry else { return }
        agent.perTurnDurationMs = durationMs
        agent.messageCount = messageCount
        entry = .agent(agent)
    }
}
