import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A resolved Claude/Codex session linked to a specific terminal
/// surface in cmux.
public struct ResolvedAgentSession: Equatable, Sendable {
    public let agentKind: AgentKind
    public let sessionID: String
    public let workspaceID: String
    public let surfaceID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let transport: SessionTransport

    public enum AgentKind: String, Equatable, Sendable {
        case claude
        case codex
    }

    public init(
        agentKind: AgentKind,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        cwd: String?,
        transcriptPath: String?,
        transport: SessionTransport = .local
    ) {
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.transport = transport
    }
}

/// Where a `ResolvedAgentSession`'s transcript bytes live and how to
/// stream them.
public enum SessionTransport: Equatable, Sendable {
    /// Transcript file is on the local filesystem; stream via
    /// `JSONLTail` (DispatchSource vnode watch).
    case local

    /// Transcript file is on a remote SSH host; stream via
    /// `RemoteJSONLStream` (`ssh exec tail -F` over the existing
    /// SSH ControlMaster socket).
    case remote(SSHTransport)
}

/// Subset of cmux's `WorkspaceRemoteConfiguration` that the package
/// needs to spawn an `ssh` subprocess. Carried in
/// `SessionTransport.remote(_:)` so the package never imports cmux
/// types.
public struct SSHTransport: Equatable, Sendable {
    public let destination: String
    public let port: Int?
    public let identityFile: String?
    /// Path to the SSH ControlMaster socket (e.g.
    /// `/tmp/cmux-ssh-501-12345-%C`). Reused so the remote tail
    /// doesn't pay another auth round-trip.
    public let controlPath: String?

    public init(
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        controlPath: String? = nil
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.controlPath = controlPath
    }
}

/// One-shot snapshot of a running agent process. Produced by the
/// process-listing seam; consumed by `AgentSessionResolver` to find
/// the session attached to a focused terminal panel.
public struct AgentProcessSnapshot: Equatable, Sendable {
    public let pid: Int
    public let agentKind: ResolvedAgentSession.AgentKind
    public let cwd: String
    /// Absolute paths of `.jsonl` files this process has currently
    /// open. The basename (without `.jsonl`) is the session id.
    public let openTranscripts: [String]

    public init(
        pid: Int,
        agentKind: ResolvedAgentSession.AgentKind,
        cwd: String,
        openTranscripts: [String]
    ) {
        self.pid = pid
        self.agentKind = agentKind
        self.cwd = cwd
        self.openTranscripts = openTranscripts
    }
}

/// Resolves a `(workspaceID, surfaceID, cwdHint)` triple to a live
/// `ResolvedAgentSession` by inspecting running processes — not by
/// reading any persisted state.
///
/// The previous shape (hook-store lookup keyed on workspaceID +
/// TTY-resume `ps` scan) broke on every cmux restart: workspace UUIDs
/// are minted fresh, so old hook records don't match; persisted TTY
/// device names were stale because the new shell spawns on a fresh
/// pty. The honest fix is to ignore both persisted layers and resolve
/// by walking the live process tree on every focus event.
///
/// Algorithm:
///   1. Enumerate every running `claude` / `codex` process on the host.
///   2. Filter to processes whose working directory matches `cwdHint`.
///   3. For each match, read its open file descriptors and pick the
///      `.jsonl` under `~/.claude/projects/` (claude) or
///      `~/.codex/sessions/` (codex). The basename is the session id.
///   4. If exactly one match remains, return a `ResolvedAgentSession`.
///      Multiple ambiguous matches → return nil.
///
/// This same path handles tab-switch, first-open, post-restart attach,
/// `claude --resume`, and `/new` mid-session — no special cases.
///
/// `@unchecked Sendable` — `FileManager` is thread-safe in practice;
/// Apple just doesn't mark it `Sendable`.
public struct AgentSessionResolver: @unchecked Sendable {
    private let listAgentProcesses: @Sendable () -> [AgentProcessSnapshot]

    public init(
        listAgentProcesses: @escaping @Sendable () -> [AgentProcessSnapshot]
            = AgentSessionResolver.defaultListAgentProcesses
    ) {
        self.listAgentProcesses = listAgentProcesses
    }

    public func resolve(
        workspaceID: String,
        surfaceID: String,
        cwdHint: String? = nil
    ) -> ResolvedAgentSession? {
        guard let cwd = Self.normalizedCwd(cwdHint), !cwd.isEmpty else {
            return nil
        }

        let processes = listAgentProcesses()
        let matches = processes.filter { process in
            Self.normalizedCwd(process.cwd) == cwd
        }

        // Ambiguous: multiple agent processes in the same cwd. Refuse
        // to guess; let the caller surface "no session attached" until
        // the ambiguity resolves on its own (one of them exits).
        guard matches.count == 1, let process = matches.first else {
            return nil
        }

        // Find the live transcript: pick the only open .jsonl. If the
        // process has multiple open transcript files (rare — happens
        // briefly during /clear or /new while old fd is still open),
        // pick the most recently modified one as a tiebreaker.
        guard let transcriptPath = pickLiveTranscript(process.openTranscripts) else {
            return nil
        }

        let sessionID = (transcriptPath as NSString)
            .lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")
        guard !sessionID.isEmpty else { return nil }

        return ResolvedAgentSession(
            agentKind: process.agentKind,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            cwd: cwd,
            transcriptPath: transcriptPath
        )
    }

    private func pickLiveTranscript(_ paths: [String]) -> String? {
        if paths.count <= 1 { return paths.first }
        // Newest mtime wins — corresponds to the session currently
        // being written. Stale fds (rare: just after /new while the
        // old session fd is closing) pick the loser.
        let fm = FileManager.default
        let withMtimes: [(path: String, mtime: Date)] = paths.compactMap { path in
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                return nil
            }
            return (path, mtime)
        }
        return withMtimes.max(by: { $0.mtime < $1.mtime })?.path
    }

    private static func normalizedCwd(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return (raw as NSString).standardizingPath
    }
}

// MARK: - Default libproc-backed process listing

#if canImport(Darwin)

extension AgentSessionResolver {
    /// Default `listAgentProcesses` impl. Walks every running process
    /// on the host via libproc, filters to `claude` / `codex` binaries,
    /// reads each match's cwd + open `.jsonl` paths.
    ///
    /// Deliberately stateless and synchronous — called per focus
    /// event (~150 ms debounced). Typical macOS host has < 1000
    /// processes; the syscall cost is dominated by `proc_pidpath`
    /// for filtering. ~1–5 ms per call in practice.
    public static let defaultListAgentProcesses: @Sendable () -> [AgentProcessSnapshot] = {
        var snapshots: [AgentProcessSnapshot] = []
        for pid in liveProcessIDs() {
            guard let path = processBinaryPath(pid: pid) else { continue }
            let basename = (path as NSString).lastPathComponent
            let kind: ResolvedAgentSession.AgentKind?
            switch basename {
            case "claude": kind = .claude
            case "codex":  kind = .codex
            default:       kind = nil
            }
            guard let agentKind = kind else { continue }
            guard let cwd = processCwd(pid: pid) else { continue }
            let openTranscripts = openAgentTranscripts(pid: pid, agentKind: agentKind)
            snapshots.append(AgentProcessSnapshot(
                pid: pid,
                agentKind: agentKind,
                cwd: cwd,
                openTranscripts: openTranscripts
            ))
        }
        return snapshots
    }

    private static func liveProcessIDs() -> [Int] {
        // proc_listallpids: pass nil/0 first to get the byte count, then allocate.
        let byteCount = proc_listallpids(nil, 0)
        guard byteCount > 0 else { return [] }
        // Add slack so newly-spawned processes between calls don't get truncated.
        let slots = Int(byteCount) / MemoryLayout<pid_t>.stride + 64
        var pids = [pid_t](repeating: 0, count: slots)
        let copiedBytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(slots * MemoryLayout<pid_t>.stride))
        }
        guard copiedBytes > 0 else { return [] }
        let copiedCount = Int(copiedBytes) / MemoryLayout<pid_t>.stride
        return pids.prefix(copiedCount).compactMap { $0 > 0 ? Int($0) : nil }
    }

    private static func processBinaryPath(pid: Int) -> String? {
        // 4096-byte buffer matches the cmux-side `cmuxTopPIDPathBufferSize`
        // convention; on Darwin `PROC_PIDPATHINFO_MAXSIZE` is 4096.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processCwd(pid: Int) -> String? {
        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDVNODEPATHINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        let cwd = withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuplePtr -> String in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in
                String(cString: ptr)
            }
        }
        return cwd.isEmpty ? nil : cwd
    }

    private static func openAgentTranscripts(
        pid: Int,
        agentKind: ResolvedAgentSession.AgentKind
    ) -> [String] {
        // 1) Find the byte size of the fd table.
        let byteCount = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let count = Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let copiedBytes = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, base, Int32(buf.count * MemoryLayout<proc_fdinfo>.stride))
        }
        guard copiedBytes > 0 else { return [] }
        let copiedCount = Int(copiedBytes) / MemoryLayout<proc_fdinfo>.stride

        // 2) For each fd that's a vnode (regular file), get its path.
        let projectsRoot: String
        switch agentKind {
        case .claude: projectsRoot = (("~/.claude/projects" as NSString).expandingTildeInPath as String)
        case .codex:  projectsRoot = (("~/.codex/sessions" as NSString).expandingTildeInPath as String)
        }
        var paths: [String] = []
        for i in 0..<copiedCount {
            let fdInfo = fds[i]
            guard fdInfo.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var vnodeInfo = vnode_fdinfowithpath()
            let expected = MemoryLayout<vnode_fdinfowithpath>.stride
            let size = proc_pidfdinfo(pid_t(pid), fdInfo.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, Int32(expected))
            guard size == expected else { continue }
            let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { tuplePtr -> String in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in
                    String(cString: ptr)
                }
            }
            guard path.hasSuffix(".jsonl") else { continue }
            guard path.hasPrefix(projectsRoot) else { continue }
            paths.append(path)
        }
        return paths
    }
}

#else

extension AgentSessionResolver {
    /// Non-Darwin fallback: returns no processes. AgentX-ray local
    /// resolution requires libproc; remote workspaces use a different
    /// transport (commit 4).
    public static let defaultListAgentProcesses: @Sendable () -> [AgentProcessSnapshot] = { [] }
}

#endif
