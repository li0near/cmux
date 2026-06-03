import Foundation

/// Per-type parser for `type: "assistant"` JSONL lines.
///
/// Drops synthetic assistant lines (`model: "<synthetic>"`) — Claude
/// Code fabricates these for interrupt stubs (`"No response
/// requested."`), API-error envelopes, and partial-response cutoffs;
/// they are noise and should not produce an `AgentTurn`.
///
/// All non-synthetic assistant lines on the active branch fold into
/// the pending `AgentTurn`. Sidechain handling sits in
/// `ClaudeLineDispatcher.route` upstream so this parser only sees
/// main-branch assistant lines.
enum AssistantLineParser {
    static func parse(
        _ line: ClaudeJSONLLine,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool
    ) -> ClaudeLineRouting {
        if line.message?.model == "<synthetic>" {
            return .skip
        }
        return ClaudeLineDispatcher.branchGated(
            line, kind: .render(.agent),
            activeBranch: activeBranch,
            activeBranchAvailable: activeBranchAvailable
        )
    }
}
