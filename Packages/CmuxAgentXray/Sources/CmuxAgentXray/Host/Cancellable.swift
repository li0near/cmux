/// A simple cancellation handle returned by `AgentXrayHost`
/// observation methods. Modelled as a class-bound protocol so the panel
/// can store it as a stored property and invalidate it in `close()`
/// without leaking the host's internal observation type.
///
/// Named `AgentXrayCancellable` rather than `Cancellable` to disambiguate
/// from Combine's `Cancellable` at host-adapter call sites in the cmux
/// app target.
///
/// Implementations are typically thin wrappers over `Combine.AnyCancellable`,
/// `NotificationCenter` observer tokens, or `Task` handles.
public protocol AgentXrayCancellable: AnyObject {
    /// Stop the underlying subscription. Must be safe to call more than
    /// once; subsequent calls are no-ops.
    func cancel()
}
