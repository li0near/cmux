import Foundation

/// Read-only reflection of the `~/.cmuxterm/claude-hook-sessions.json` file
/// that `cmux claude-hook session-start` writes.
///
/// Matches the schema in CLI/cmux.swift:423-491. We only decode the fields
/// the panel needs (sessionId → surfaceId/transcriptPath/cwd/pid). Unknown
/// fields are skipped; future schema additions won't break us.
public struct ClaudeHookSessionRecord: Equatable, Sendable {
    public let sessionId: String
    public let workspaceId: String
    public let surfaceId: String
    public let cwd: String?
    public let transcriptPath: String?
    public let pid: Int?
    public let updatedAt: Date

    public init(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        pid: Int?,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.pid = pid
        self.updatedAt = updatedAt
    }
}

/// In-process reader for the Claude hook session store. Loads the JSON file
/// on demand and answers per-surface and per-workspace queries.
///
/// File watching is deliberately *not* installed here — observers attach a
/// `DispatchSource` via `startWatching(_:)` only when there's a live consumer
/// (the inspector panel). Avoids waking the app for hook updates when the
/// panel isn't open.
public final class ClaudeHookSessionStore {

    /// Default path. Honors `CMUX_CLAUDE_HOOK_STATE_PATH` and
    /// `CMUX_AGENT_HOOK_STATE_DIR` overrides, matching the CLI's logic at
    /// `CLI/cmux.swift:506-516`.
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
    private let queue = DispatchQueue(label: "com.cmux.agentInspector.hookStore", qos: .utility)

    private nonisolated(unsafe) var watchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var watchedFD: Int32 = -1

    public init(path: String = ClaudeHookSessionStore.defaultPath, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    deinit {
        stopWatching()
    }

    /// All known sessions, keyed by sessionId. Returns an empty dict if the
    /// file is missing or malformed.
    public func loadAll() -> [String: ClaudeHookSessionRecord] {
        guard fileManager.fileExists(atPath: path) else { return [:] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        // Tolerate both nested `{ sessions: { sid: {...} } }` (current) and
        // the legacy flat `{ sid: {...} }` layout — same approach as
        // `Sources/Feed/FeedCoordinator.swift:357-360`.
        let raw_sessions: [String: Any]
        if let nested = raw["sessions"] as? [String: Any] {
            raw_sessions = nested
        } else {
            raw_sessions = raw
        }

        var out: [String: ClaudeHookSessionRecord] = [:]
        for (sid, value) in raw_sessions {
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
            out[sid] = ClaudeHookSessionRecord(
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

    /// Most recently-updated record for the given workspace+surface. Multiple
    /// sessions can reference the same surface (e.g. /clear bumps a new
    /// sessionId); the freshest one wins.
    public func record(forWorkspaceId workspaceId: String, surfaceId: String) -> ClaudeHookSessionRecord? {
        loadAll()
            .values
            .filter { $0.workspaceId == workspaceId && $0.surfaceId == surfaceId }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func record(forSessionId sessionId: String) -> ClaudeHookSessionRecord? {
        loadAll()[sessionId]
    }

    /// Install a file-system watch on the underlying JSON file. The callback
    /// fires (debounced 100ms, on the store's serial queue) whenever the
    /// file is written, deleted, or atomically replaced.
    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — poll the directory until it appears.
            // Simpler: rely on the consumer to retry; we can install a watch
            // when the file shows up later.
            scheduleDirectoryRetry(onChange)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .extend, .rename, .attrib],
            queue: queue
        )
        var pending = false
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
                self.startWatching(onChange)
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

    private func scheduleDirectoryRetry(_ onChange: @escaping () -> Void) {
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
