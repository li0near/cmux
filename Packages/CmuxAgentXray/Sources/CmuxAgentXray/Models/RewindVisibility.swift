/// Status-bar pill toggle: should rewound (abandoned-branch) entries be
/// surfaced in the active list?
///
/// - `.link` (default) — `SynthesizedEntry.branchLink` rows appear at
///   each divergence point in the active list. Clicking opens the
///   abandoned branch's transcript in a sibling detail tab. The
///   transcript builder's emission is shaped for this state.
/// - `.hide` — branch-link rows are dropped from the active list
///   entirely. Useful when scanning a heavily-rewound session.
public enum RewindVisibility: String, Equatable, Sendable, CaseIterable {
    case link
    case hide

    public var label: String {
        switch self {
        case .link: return "rewinds:link"
        case .hide: return "rewinds:hide"
        }
    }

    /// Cycle to the next state — used by the status-bar pill on click.
    public func cycled() -> RewindVisibility {
        switch self {
        case .link: return .hide
        case .hide: return .link
        }
    }
}
