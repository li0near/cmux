import Foundation

/// Inspector toggle: how should chunk rows be expanded by default when
/// they enter the snap turn?
///
/// - `.allCollapsed` (default) — every chunk row starts collapsed; the
///   user expands individually. Matches the user's stated preference of
///   "history being expanded would be a nightmare."
/// - `.autoExpandSnap` — chunks of the **current snap turn** auto-expand
///   on every filter transition. History (older anchored turns,
///   pre-anchored zone) stays collapsed regardless.
///
/// Per-row manual collapse-overrides win in both states. The "Collapse
/// all" action separately resets every row's local override; the
/// "Expand snap" action one-shot expands the current snap turn's chunks.
enum InspectorExpansionMode: String, CaseIterable, Equatable {
    case allCollapsed
    case autoExpandSnap

    var label: String {
        switch self {
        case .allCollapsed: return "expand:off"
        case .autoExpandSnap: return "expand:snap"
        }
    }

    func cycled() -> InspectorExpansionMode {
        switch self {
        case .allCollapsed: return .autoExpandSnap
        case .autoExpandSnap: return .allCollapsed
        }
    }
}
