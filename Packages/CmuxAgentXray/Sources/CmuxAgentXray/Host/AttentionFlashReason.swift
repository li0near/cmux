/// Why the host wants the panel to flash. Routed through
/// `AgentXrayPanel.triggerFlash(reason:)` so the view layer can decide
/// the visual treatment.
public enum AttentionFlashReason: Equatable, Sendable {
    /// A focus-related event (workspace activation, hot-key surface flip).
    case focus
    /// New transcript activity worth highlighting.
    case activity
    /// A session-attach moment — the inspector hooked into a fresh
    /// agent transcript.
    case attach
    /// Generic catch-all.
    case other
}
