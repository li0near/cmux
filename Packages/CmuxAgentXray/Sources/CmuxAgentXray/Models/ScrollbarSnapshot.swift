/// Pure value snapshot of the inputs that drive the visible-entries
/// filter algorithm. Decouples the algorithm from the host's
/// scrollbar type so unit tests can drive it without spinning up a
/// terminal surface.
public struct ScrollbarSnapshot: Equatable, Sendable {
    /// Total scrollback length (rows).
    public let total: UInt64
    /// Top-of-viewport row.
    public let offset: UInt64
    /// Viewport height (rows).
    public let len: UInt64

    public init(total: UInt64, offset: UInt64, len: UInt64) {
        self.total = total
        self.offset = offset
        self.len = len
    }
}
