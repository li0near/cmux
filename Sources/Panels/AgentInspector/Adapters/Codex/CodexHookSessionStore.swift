import Foundation

/// Read-only mirror of `~/.cmuxterm/codex-hook-sessions.json`. Same schema as
/// the Claude hook store; only the file name differs.
public final class CodexHookSessionStore {

    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_CODEX_HOOK_STATE_PATH"]?
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
            .appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
            .path
        }
        return NSString(string: "~/.cmuxterm/codex-hook-sessions.json")
            .expandingTildeInPath
    }

    private let path: String
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.cmux.agentInspector.codexHookStore", qos: .utility)
    private nonisolated(unsafe) var watchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var watchedFD: Int32 = -1

    public init(path: String = CodexHookSessionStore.defaultPath, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    deinit { stopWatching() }

    public func loadAll() -> [String: ClaudeHookSessionRecord] {
        // Reuse `ClaudeHookSessionRecord` since the schema is identical
        // (sessionId / workspaceId / surfaceId / cwd / transcriptPath).
        guard fileManager.fileExists(atPath: path) else { return [:] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let raw_sessions: [String: Any]
        if let nested = raw["sessions"] as? [String: Any] {
            raw_sessions = nested
        } else {
            raw_sessions = raw
        }
        var out: [String: ClaudeHookSessionRecord] = [:]
        for (sid, value) in raw_sessions {
            guard let entry = value as? [String: Any] else { continue }
            guard let workspaceId = entry["workspaceId"] as? String, !workspaceId.isEmpty,
                  let surfaceId = entry["surfaceId"] as? String, !surfaceId.isEmpty
            else { continue }
            let updatedAt = (entry["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            // Codex stores a `rolloutPath` rather than `transcriptPath` in
            // some versions; accept either for forward-compatibility.
            let transcript = (entry["transcriptPath"] as? String) ?? (entry["rolloutPath"] as? String)
            out[sid] = ClaudeHookSessionRecord(
                sessionId: sid,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: entry["cwd"] as? String,
                transcriptPath: transcript,
                pid: entry["pid"] as? Int,
                updatedAt: updatedAt
            )
        }
        return out
    }

    public func record(forWorkspaceId workspaceId: String, surfaceId: String) -> ClaudeHookSessionRecord? {
        loadAll()
            .values
            .filter { $0.workspaceId == workspaceId && $0.surfaceId == surfaceId }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                guard let self else { return }
                if self.fileManager.fileExists(atPath: self.path) {
                    self.startWatching(onChange)
                    onChange()
                }
            }
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
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.startWatching(onChange)
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        watchedFD = fd
        watchSource = source
        source.resume()
    }

    public func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
    }
}
