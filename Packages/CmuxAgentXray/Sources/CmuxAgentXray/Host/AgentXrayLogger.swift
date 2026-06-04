import Foundation

/// Host-injected logger seam. The package emits messages via this
/// protocol; the cmux app provides a concrete implementation that
/// routes to `os.Logger` (production retention, sysdiagnose) and
/// `cmuxDebugLog` (DEBUG-build live tail).
///
/// Levels follow Apple's unified-logging vocabulary:
///   - `.debug` — verbose dev-time signal; release builds may elide.
///   - `.info` — informational; memory-only by default.
///   - `.notice` — default-level event; persisted to disk briefly.
///   - `.warning` — user-actionable failure; persisted longer; rolls
///     into sysdiagnose.
///   - `.error` — broken invariant; high-priority.
///
/// **Privacy convention:** callers MUST NOT interpolate raw user
/// content (transcript bodies, file path components that contain user
/// directory names, etc.). The host adapter forwards interpolated
/// strings to `os.Logger` with `.public` privacy, so anything passed
/// here ends up visible in Console.app and sysdiagnose. Sanitize at
/// the call site (e.g. log "transcript open failed after N retries"
/// rather than "failed to open /Users/<user>/.claude/projects/...").
///
/// Implementations must be `Sendable` because callers include
/// `@unchecked Sendable` types like `JSONLTail` (queue-isolated).
public protocol AgentXrayLogger: Sendable {
    func debug(_ message: @autoclosure () -> String)
    func info(_ message: @autoclosure () -> String)
    func notice(_ message: @autoclosure () -> String)
    func warning(_ message: @autoclosure () -> String)
    func error(_ message: @autoclosure () -> String)
}

/// No-op `AgentXrayLogger`. Useful for tests and as a safe default
/// when the host hasn't wired up a real logger.
public struct NoOpAgentXrayLogger: AgentXrayLogger {
    public init() {}
    public func debug(_ message: @autoclosure () -> String) {}
    public func info(_ message: @autoclosure () -> String) {}
    public func notice(_ message: @autoclosure () -> String) {}
    public func warning(_ message: @autoclosure () -> String) {}
    public func error(_ message: @autoclosure () -> String) {}
}
