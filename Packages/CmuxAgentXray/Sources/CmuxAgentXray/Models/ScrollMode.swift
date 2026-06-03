/// Two-state mode for the inspector's scroll behaviour. Picked from a
/// pill in the panel status bar.
///
/// - `.free`: render the entire transcript independently of the paired
///   terminal.
/// - `.snap`: filter to entries belonging to the turn(s) currently
///   visible in the paired terminal viewport. Tail-follow is implicit
///   when the terminal is at the bottom of its scrollback.
public enum ScrollMode: Int, Equatable, Sendable, CaseIterable {
    case free
    case snap

    public var label: String {
        switch self {
        case .free: return "free"
        case .snap: return "snap"
        }
    }
}
