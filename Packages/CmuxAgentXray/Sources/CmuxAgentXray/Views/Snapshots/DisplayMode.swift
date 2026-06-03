/// Render mode for an `Entry`. Drives caps lookup and per-section
/// inline-vs-link policy.
public enum DisplayMode: Equatable, Sendable {
    /// Live transcript panel — apply per-section inline caps; long
    /// content overflows to an `↗ Open detail` link.
    case compact
    /// Detail tab — render the full body unfolded, no caps applied.
    case fullDetail
}
