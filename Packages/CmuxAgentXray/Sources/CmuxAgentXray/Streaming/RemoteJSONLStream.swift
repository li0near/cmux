import Foundation

/// Streams JSONL bytes from a remote file via `ssh exec tail -F`.
///
/// The transport piggybacks on cmux's existing SSH ControlMaster
/// socket (the same multiplexed connection that hosts the workspace's
/// terminals), so no fresh auth round-trip is needed and no daemon-
/// side code (cmuxd-remote) requires modification — pure `ssh exec`.
///
/// The remote command is:
/// ```
/// stdbuf -oL tail -n +1 -F -- '<path>'
/// ```
///
///   - `stdbuf -oL`: forces `tail`'s stdout to line-buffer so the SSH
///     server doesn't TCP-buffer a partial JSONL line.
///   - `tail -n +1`: re-emits the file from the start (matches
///     `JSONLTail`'s "synchronous initial drain then watch appends"
///     contract).
///   - `tail -F`: follow across renames/truncates (matches the file
///     rotation behaviour of Claude Code's transcript writer).
///
/// Line framing reuses the same `JSONLLineFramer` as `JSONLTail`, so
/// UTF-8 boundary safety + line-carry semantics are identical.
///
/// The class spawns a single `Process` running `ssh`. On termination
/// (network drop, SIGPIPE, etc.) it backs off and respawns. `stop()`
/// terminates the subprocess synchronously.
///
/// `@unchecked Sendable` — mutable state is queue-isolated.
public final class RemoteJSONLStream: @unchecked Sendable {

    public typealias LinesHandler = @Sendable ([String]) -> Void

    private let transport: SSHTransport
    private let remotePath: String
    private let logger: any AgentXrayLogger
    private let onLines: LinesHandler

    private let queue = DispatchQueue(
        label: "com.cmux.agentXray.remoteJSONLStream",
        qos: .utility
    )

    private nonisolated(unsafe) var process: Process?
    private nonisolated(unsafe) var readSource: (any DispatchSourceRead)?
    private nonisolated(unsafe) var framer = JSONLLineFramer()
    private nonisolated(unsafe) var stopped = false
    private nonisolated(unsafe) var respawnAttempts = 0
    private static let maxRespawnAttempts = 8

    public init(
        transport: SSHTransport,
        remotePath: String,
        logger: any AgentXrayLogger = NoOpAgentXrayLogger(),
        onLines: @escaping LinesHandler
    ) {
        self.transport = transport
        self.remotePath = remotePath
        self.logger = logger
        self.onLines = onLines
    }

    deinit {
        // Cancel synchronously here — by definition no other code can
        // hold a strong reference to self once deinit runs.
        readSource?.cancel()
        readSource = nil
        process?.terminate()
    }

    public func start() {
        queue.async { [weak self] in
            self?.spawn()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.readSource?.cancel()
            self.readSource = nil
            self.process?.terminate()
            self.process = nil
        }
    }

    // MARK: - Subprocess management

    private func spawn() {
        guard !stopped else { return }
        framer.reset()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArgs()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        // Don't inherit stdin from the parent process.
        proc.standardInput = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.handleSubprocessExit()
            }
        }

        do {
            try proc.run()
        } catch {
            logger.warning("RemoteJSONLStream: failed to spawn ssh — \(error.localizedDescription)")
            scheduleRespawn()
            return
        }

        process = proc

        // Read stdout via DispatchSource for non-blocking reads.
        let fd = pipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleStdoutAvailable(fd: fd)
        }
        source.setCancelHandler {
            // The Process owns the underlying pipe; closing fd here
            // would race with Process tear-down. Process.terminate
            // and waitUntilExit handle cleanup.
        }
        readSource = source
        source.resume()
    }

    private func sshArgs() -> [String] {
        var args: [String] = ["-T"]  // disable pseudo-tty (just exec)
        if let port = transport.port {
            args += ["-p", String(port)]
        }
        if let identity = transport.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let controlPath = transport.controlPath, !controlPath.isEmpty {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        // Be patient with transient drops; the existing ControlMaster
        // session usually keeps things up.
        args += ["-o", "ServerAliveInterval=15"]
        args += ["-o", "ServerAliveCountMax=4"]
        args.append(transport.destination)
        // Quote the remote path defensively (single quotes; escape
        // embedded single quotes via the standard '"'"' dance).
        let quoted = "'" + remotePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        args.append("stdbuf -oL tail -n +1 -F -- \(quoted)")
        return args
    }

    // MARK: - Stdout handling

    private func handleStdoutAvailable(fd: Int32) {
        // Drain everything currently available without blocking.
        var chunk = Data()
        var temp = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = temp.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return read(fd, base, ptr.count)
            }
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                return
            }
            chunk.append(temp, count: n)
            // Prevent a misbehaving remote from filling memory in
            // one read storm.
            if chunk.count >= 1 * 1024 * 1024 { break }
        }
        guard !chunk.isEmpty else { return }
        let lines = framer.ingest(chunk)
        if !lines.isEmpty {
            onLines(lines)
        }
    }

    // MARK: - Respawn on subprocess exit

    private func handleSubprocessExit() {
        readSource?.cancel()
        readSource = nil
        process = nil
        respawnAttempts += 1
        guard respawnAttempts <= Self.maxRespawnAttempts else {
            logger.warning("RemoteJSONLStream: gave up after \(respawnAttempts) ssh respawn attempts")
            return
        }
        scheduleRespawn()
    }

    private func scheduleRespawn() {
        // 1, 2, 4, 8, 16, 30, 30, 30 seconds.
        let delaySeconds = min(30, 1 << min(max(0, respawnAttempts - 1), 5))
        queue.asyncAfter(deadline: .now() + .seconds(delaySeconds)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.spawn()
        }
    }
}
