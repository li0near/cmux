/// Auto-expand toggle: how should new entries be expanded by default
/// when they enter the snap turn?
///
/// - `.allCollapsed` (default) — every entry starts collapsed; the user
///   expands individually. Matches the user's stated preference of
///   "history being expanded would be a nightmare."
/// - `.autoExpand` — entries of the **current snap turn** auto-expand
///   on every filter transition. History (older anchored turns,
///   pre-anchored zone) stays collapsed regardless. The snap-mode gate
///   is enforced by the panel's `shouldAutoExpandNewItems` predicate
///   (`isLockedToTurn && expansionMode == .autoExpand`), so the case
///   name carries no `Snap` suffix.
///
/// Per-entry manual expansion overrides win in both states.
public enum ExpansionMode: String, Equatable, Sendable, CaseIterable {
    case allCollapsed
    case autoExpand

    public var label: String {
        switch self {
        case .allCollapsed: return "expand:off"
        case .autoExpand:   return "expand:snap"
        }
    }

    /// Cycle to the next state — used by the status-bar pill on click.
    public func cycled() -> ExpansionMode {
        switch self {
        case .allCollapsed: return .autoExpand
        case .autoExpand:   return .allCollapsed
        }
    }
}
