import Foundation

/// Inspector toggle: should rewound (abandoned-branch) chunks be surfaced
/// in the active list?
///
/// - `.link` (default) — `BranchLink` rows appear at each divergence point
///   in the active list. Clicking opens the abandoned branch's chunks in
///   a sibling detail tab. Phase A's emission is shaped for this state.
/// - `.hide` — `BranchLink` rows are dropped from the active list entirely.
///   Useful when scanning a heavily-rewound session.
enum InspectorRewindVisibility: String, CaseIterable, Equatable {
    case link
    case hide

    var label: String {
        switch self {
        case .link: return "rewinds:link"
        case .hide: return "rewinds:hide"
        }
    }

    /// Cycle to the next state (used by the status-bar pill on click).
    func cycled() -> InspectorRewindVisibility {
        switch self {
        case .link: return .hide
        case .hide: return .link
        }
    }
}
