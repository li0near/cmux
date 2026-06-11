import Foundation

/// Per-type parser for `type: "assistant"` JSONL lines.
///
/// Drops synthetic assistant lines (`model: "<synthetic>"`) — Claude
/// Code fabricates these for interrupt stubs (`"No response
/// requested."`), API-error envelopes, and partial-response cutoffs;
/// they are noise and should not produce an `AgentEntry`.
///
/// All non-synthetic assistant lines fold into the pending agent
/// turn (the builder detects rewinds inline at user-prompt arrival
/// and slices the abandoned tail — there is no active-branch
/// filter). Sidechain handling sits in `ClaudeLineDispatcher.route`
/// upstream so this parser only sees main-branch assistant lines.
enum AssistantLineDispatcher {
    static func parse(_ line: ClaudeJSONLLine) -> ClaudeLineRouting {
        if line.message?.model == "<synthetic>" {
            return .skip
        }
        return .render(.agent)
    }
}
