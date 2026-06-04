import Foundation

/// Lifecycle stage of the panel's attach-to-session pipeline.
/// Drives the status-bar yellow-state label and is reserved for
/// future fine-grained attach progress reporting (the panel today
/// only observes the bookend states: nothing-attached and
/// transcript-streaming).
///
/// Mapping to the 3-color status-bar precedence per
/// `VISUAL_PASS_REVIEW.md` §1:
///
///   `.idle`, `.awaitingSession`     → RED   "Detached" / placeholder
///   `.sessionHooked(sessionID:)`,
///   `.locatingTranscript`,
///   `.streamingNoEntries`           → YELLOW (per-stage label)
///   `.streaming(turns:, tokens:)`   → GREEN ("attached <kind>…" text)
///
/// A stream error overrides everything to RED with the error message.
public enum AttachStage: Equatable, Sendable {
    /// Panel just opened; nothing tracked yet.
    case idle
    /// Focus tracking is live but no session has been resolved.
    case awaitingSession
    /// Session resolved; transcript file path lookup pending.
    case sessionHooked(sessionID: String)
    /// Transcript file located; tail not yet attached.
    case locatingTranscript
    /// Tail attached; awaiting the first transcript entry.
    case streamingNoEntries
    /// Transcript live with at least one entry.
    case streaming(turnCount: Int, tokenTotal: Int)
}

extension AttachStage {

    /// Derive the current stage from the panel's observable state.
    /// Today's panel only distinguishes three of the six cases:
    ///   - no session              → `.idle`
    ///   - session + zero entries  → `.streamingNoEntries`
    ///   - session + entries       → `.streaming(turnCount:, tokenTotal:)`
    /// The intermediate cases (`awaitingSession`, `sessionHooked`,
    /// `locatingTranscript`) are reserved for future attach lifecycle
    /// instrumentation — they're valid enum values but no derivation
    /// path produces them today.
    public static func derive(
        resolvedSession: ResolvedAgentSession?,
        entries: [Entry]
    ) -> AttachStage {
        guard resolvedSession != nil else {
            return .idle
        }
        if entries.isEmpty {
            return .streamingNoEntries
        }
        let turnCount = entries.reduce(0) { acc, entry in
            if case .agent = entry { return acc + 1 }
            return acc
        }
        let tokenTotal = entries.reduce(0) { acc, entry in
            if case .agent(let a) = entry {
                return acc
                    + a.usage.inputTokens
                    + a.usage.outputTokens
                    + a.usage.cacheReadTokens
                    + a.usage.cacheCreationTokens
            }
            return acc
        }
        return .streaming(turnCount: turnCount, tokenTotal: tokenTotal)
    }
}
