import Foundation

/// Three-state mode for the inspector's auto-scroll behaviour. Mutually
/// exclusive — picked from a pill in the inspector status bar.
///
/// - `off`: do not auto-scroll. User scrolls inspector and terminal
///   independently.
/// - `followTail`: when new chunks append at the bottom, auto-scroll the
///   inspector to the latest row. Existing pre-Phase-B behaviour.
/// - `syncToTerminal`: subscribe to the paired terminal's
///   `ghosttyDidUpdateScrollbar` and scroll the inspector to the chunk
///   matching the terminal's currently-visible row range. Uses
///   `TurnAnchorStore` for the row → chunk mapping.
enum InspectorSyncMode: Int, Equatable, CaseIterable {
    case off
    case followTail
    case syncToTerminal

    var label: String {
        switch self {
        case .off: return "Off"
        case .followTail: return "Tail"
        case .syncToTerminal: return "Sync"
        }
    }
}
