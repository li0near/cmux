public import Foundation

/// Read-only reflection of `~/.cmuxterm/claude-hook-sessions.json`,
/// written by the cmux CLI's `claude-hook session-start` handler.
///
/// File watching is opt-in via `startWatching(_:)`: observers attach a
/// `DispatchSource` only when there's a live consumer (the panel).
/// Avoids waking the app for hook updates when the panel isn't open.
///
/// Thread-safety: the store is `@unchecked Sendable` — its mutable
/// state (`watchSource`, `watchedFD`) is guarded by the private
/// `queue` (dispatch-queue-serialized). Loaders are stateless reads
/// that allocate fresh decoders per call.
public final class ClaudeHookSessionStore: @unchecked Sendable {

    /// Default path. Honors `CMUX_CLAUDE_HOOK_STATE_PATH` and
    /// `CMUX_AGENT_HOOK_STATE_DIR` env overrides — same precedence
    /// that the cmux CLI uses when writing the file.
    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_CLAUDE_HOOK_STATE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        if let dirOverride = env["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dirOverride.isEmpty {
            return URL(
                fileURLWithPath: NSString(string: dirOverride).expandingTildeInPath,
                isDirectory: true
            )
            .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
            .path
        }
        return NSString(string: "~/.cmuxterm/claude-hook-sessions.json")
            .expandingTildeInPath
    }

    private let path: String
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.cmux.agentXray.claudeHookStore", qos: .utility)

    private nonisolated(unsafe) var watchSource: (any DispatchSourceFileSystemObject)?
    private nonisolated(unsafe) var watchedFD: Int32 = -1

    public init(
        path: String = ClaudeHookSessionStore.defaultPath,
        fileManager: FileManager = .default
    ) {
        self.path = path
        self.fileManager = fileManager
    }

    deinit {
        watchSource?.cancel()
    }

    /// All known sessions, keyed by sessionId. Empty dict if the file
    /// is missing or malformed.
    public func loadAll() -> [String: AgentHookSessionRecord] {
        guard fileManager.fileExists(atPath: path) else { return [:] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        // Tolerate both nested `{ sessions: { sid: {...} } }` (current)
        // and the legacy flat `{ sid: {...} }` layout.
        let rawSessions: [String: Any]
        if let nested = raw["sessions"] as? [String: Any] {
            rawSessions = nested
        } else {
            rawSessions = raw
        }

        var out: [String: AgentHookSessionRecord] = [:]
        for (sid, value) in rawSessions {
            guard let entry = value as? [String: Any] else { continue }
            guard let workspaceId = entry["workspaceId"] as? String,
                  !workspaceId.isEmpty,
                  let surfaceId = entry["surfaceId"] as? String,
                  !surfaceId.isEmpty
            else { continue }
            let updatedAt: Date
            if let v = entry["updatedAt"] as? Double {
                updatedAt = Date(timeIntervalSince1970: v)
            } else {
                updatedAt = .distantPast
            }
            out[sid] = AgentHookSessionRecord(
                sessionId: sid,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: entry["cwd"] as? String,
                transcriptPath: entry["transcriptPath"] as? String,
                pid: entry["pid"] as? Int,
                updatedAt: updatedAt
            )
        }
        return out
    }

    /// Most recently-updated record for the given (workspace, surface)
    /// pair. Multiple sessions can reference the same surface (e.g.
    /// `/clear` bumps a new sessionId); the freshest one wins.
    public func record(
        forWorkspaceId workspaceId: String,
        surfaceId: String
    ) -> AgentHookSessionRecord? {
        loadAll()
            .values
            .filter { $0.workspaceId == workspaceId && $0.surfaceId == surfaceId }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func record(forSessionId sessionId: String) -> AgentHookSessionRecord? {
        loadAll()[sessionId]
    }

    /// Install a file-system watch. The callback fires (debounced 100
    /// ms, on the store's serial queue) whenever the file is written,
    /// deleted, or atomically replaced.
    public func startWatching(_ onChange: @escaping @Sendable () -> Void) {
        stopWatching()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleDirectoryRetry(onChange)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .extend, .rename, .attrib],
            queue: queue
        )
        nonisolated(unsafe) var pending = false
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !pending {
                pending = true
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    pending = false
                    onChange()
                }
            }
            // If file rotated, re-establish the watch on the new inode.
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.queue.async { [weak self] in
                    self?.startWatching(onChange)
                }
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        watchedFD = fd
        watchSource = source
        source.resume()
    }

    public func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
    }

    private func scheduleDirectoryRetry(_ onChange: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: self.path) {
                self.startWatching(onChange)
                onChange()
            } else {
                self.scheduleDirectoryRetry(onChange)
            }
        }
    }
}
