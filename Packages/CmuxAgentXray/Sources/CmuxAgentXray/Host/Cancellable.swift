/// A simple cancellation handle returned by `AgentXrayHost`
/// observation methods. Modelled as a class-bound protocol so the panel
/// can store it as a stored property and invalidate it in `close()`
/// without leaking the host's internal observation type.
///
/// Implementations are typically thin wrappers over `Combine.AnyCancellable`,
/// `NotificationCenter` observer tokens, or `Task` handles.
public protocol Cancellable: AnyObject {
    /// Stop the underlying subscription. Must be safe to call more than
    /// once; subsequent calls are no-ops.
    func cancel()
}
