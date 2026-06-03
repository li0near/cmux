/// Per-turn timing stamp paired with an `AgentTurn` at flush time.
/// Source: `system, subtype:turn_duration` JSONL lines, where
/// `parentUuid` points at the assistant message the turn ended on.
struct TurnDurationStamp: Equatable {
    let durationMs: Int
    let messageCount: Int

    init(durationMs: Int, messageCount: Int) {
        self.durationMs = durationMs
        self.messageCount = messageCount
    }
}

/// Pure-function resolver for `system.subtype:turn_duration` lines.
///
/// `turn_duration` lines are written by Claude Code at the END of each
/// turn (after the final assistant message lands), so by the time the
/// per-line dispatch loop reaches them, the corresponding `AgentTurn`
/// has already been flushed. Pre-pass collection keys the duration by
/// `parentUuid` (the assistant message the turn ended on); the
/// transcript builder picks it up at flush time.
struct ClaudeTurnDurationResolution: Equatable {
    /// Map of `assistant-message-uuid → turn-duration-stamp`. Lookup
    /// happens by the agent turn's `lastMessageUuid` at flush time.
    let stamps: [String: TurnDurationStamp]

    init(stamps: [String: TurnDurationStamp]) {
        self.stamps = stamps
    }
}

enum ClaudeTurnDurationResolver {
    static func resolve(lines: [ClaudeJSONLLine]) -> ClaudeTurnDurationResolution {
        var stamps: [String: TurnDurationStamp] = [:]
        for line in lines
        where line.type == "system" && line.subtype == "turn_duration" {
            guard let parent = line.parentUuid, let ms = line.durationMs else { continue }
            stamps[parent] = TurnDurationStamp(
                durationMs: ms,
                messageCount: line.messageCount ?? 0
            )
        }
        return ClaudeTurnDurationResolution(stamps: stamps)
    }
}
