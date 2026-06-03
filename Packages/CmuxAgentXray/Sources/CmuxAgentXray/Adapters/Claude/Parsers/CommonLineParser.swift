import Foundation

/// Cross-type catch-all for JSONL `type` values that need no per-type
/// branching: session-orphan metadata (always skip) and one-shot
/// direct routes (currently `pr-link`).
///
/// Returns `nil` to signal "this type is not Common-handled — caller
/// should dispatch to a per-type parser." Returning `nil` also causes
/// the dispatcher to log unknown JSONL types in DEBUG so new envelope
/// shapes from future Claude Code releases surface fast.
enum CommonLineParser {
    /// JSONL `type` values that carry session-global metadata or
    /// telemetry the panel ignores.
    private static let skipTypes: Set<String> = [
        "permission-mode",          // session-orphan: permission state
        "agent-name",               // session-orphan: rename display name
        "custom-title",             // session-orphan: session title
        "queue-operation",          // consumed by ClaudeQueuedPromptResolver
        "file-history-snapshot",    // session-orphan: file backup index
        "last-prompt",              // consumed by ClaudeBranchResolver
        "progress",                 // sub-agent hook telemetry
    ]

    /// JSONL `type` values whose entire treatment is a single
    /// `ClaudeLineRouting` value with no internal branching.
    private static let directRoutes: [String: ClaudeLineRouting] = [
        "pr-link": .renderSpecial(.prLink)
    ]

    /// Returns the routing for `line` if Common owns this type, else
    /// `nil`. Caller falls back to a per-type parser on `nil`.
    static func parse(_ line: ClaudeJSONLLine) -> ClaudeLineRouting? {
        if line.isSessionOrphanMetadata { return .skip }
        if line.isLastPromptMarker { return .skip }
        if skipTypes.contains(line.type) { return .skip }
        if let direct = directRoutes[line.type] { return direct }
        return nil
    }
}
