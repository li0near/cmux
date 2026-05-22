import Foundation

/// Two-state mode for the inspector's filter behaviour. Picked from a pill
/// in the inspector status bar.
///
/// - `off`: free scroll. The inspector renders the entire transcript
///   independently of the paired terminal.
/// - `snap`: visible-turn filter. The inspector renders only chunks
///   belonging to the turn(s) currently visible in the paired terminal's
///   viewport. Tail-follow is implicit when the terminal is at the bottom
///   of its scrollback (regime 1 of `computeVisibleTurnIds`).
enum InspectorSyncMode: Int, Equatable, CaseIterable {
    case off
    case snap

    var label: String {
        switch self {
        case .off: return "free"
        case .snap: return "snap"
        }
    }
}
