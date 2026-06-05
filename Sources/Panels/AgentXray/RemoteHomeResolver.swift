import AppKit
import CmuxAgentXray
import CryptoKit
import Foundation
import OSLog

/// Resolves `$HOME` on a remote SSH endpoint via `ssh exec echo $HOME`,
/// caches the result in `UserDefaults`, and exposes both an immediate
/// cached read and an async resolve-or-fetch.
///
/// The cached value is keyed by `(destination, port, identityFile,
/// controlPath)` so AgentX-ray correctly distinguishes "ubuntu@a" from
/// "ubuntu@b" — workspaces with multiple SSH'd terminals into different
/// hosts each get their own entry. `$HOME` rarely changes for a given
/// user@host so the cache survives app restarts via `UserDefaults`.
///
/// The `ssh` invocation includes `-o ControlPath=<path>` and
/// `-o ControlMaster=no` when a `controlPath` is present, so the
/// resolution rides cmux's existing ControlMaster connection (sub-
/// second; no fresh auth round-trip).
///
/// Operations are read-only: `echo $HOME` does no remote filesystem
/// write. A read-only SSH key suffices.
@MainActor
@available(macOS 15, *)
final class RemoteHomeResolver {

    /// Run an ssh subprocess and return its stdout (trimmed). Injected
    /// at the seam so tests don't shell out — production wiring spawns
    /// `/usr/bin/ssh` with the supplied argv.
    typealias SSHRunner = @MainActor @Sendable ([String]) async throws -> String

    enum ResolveError: Error, Sendable {
        case nonZeroExit(code: Int32, stderr: String)
        case timeout
        case emptyHome
    }

    private let defaults: UserDefaults
    private let runner: SSHRunner
    private let timeout: Duration
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "AgentXray.RemoteHome")
    private static let keyPrefix = "agentXray.ssh.home."

    init(
        defaults: UserDefaults = .standard,
        timeout: Duration = .seconds(5),
        runner: @escaping SSHRunner = RemoteHomeResolver.defaultRunner
    ) {
        self.defaults = defaults
        self.timeout = timeout
        self.runner = runner
    }

    // MARK: - Public API

    /// Returns the cached `$HOME` for the endpoint, or nil if unresolved.
    func cached(for transport: SSHTransport) -> String? {
        defaults.string(forKey: Self.cacheKey(for: transport))
    }

    /// Returns a usable `$HOME`. If cached, returns immediately. If not,
    /// spawns one `ssh` subprocess (mocked in tests), caches the result,
    /// returns it. Throws on non-zero exit or timeout.
    @discardableResult
    func resolve(for transport: SSHTransport) async throws -> String {
        if let cached = cached(for: transport) {
            return cached
        }
        let args = Self.sshArgs(for: transport)
        let stdout = try await withTimeout(timeout) { [runner] in
            try await runner(args)
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.logger.warning("Empty $HOME from \(transport.destination, privacy: .public)")
            throw ResolveError.emptyHome
        }
        // Strip a trailing slash so callers can append "/.claude/..."
        // without worrying about double slashes.
        let normalized = trimmed.hasSuffix("/") && trimmed.count > 1
            ? String(trimmed.dropLast())
            : trimmed
        defaults.set(normalized, forKey: Self.cacheKey(for: transport))
        return normalized
    }

    /// Clear the cache entry for an endpoint. Useful in tests; not
    /// currently exposed in user-facing UI.
    func invalidate(for transport: SSHTransport) {
        defaults.removeObject(forKey: Self.cacheKey(for: transport))
    }

    // MARK: - Key + argv builders

    static func cacheKey(for transport: SSHTransport) -> String {
        let composite = [
            transport.destination,
            transport.port.map(String.init) ?? "",
            transport.identityFile ?? "",
            transport.controlPath ?? "",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(composite.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(keyPrefix)\(hex)"
    }

    /// Argv shape mirrors `RemoteJSONLStream.sshArgs()` so the same
    /// connection/auth path is reused.
    static func sshArgs(for transport: SSHTransport) -> [String] {
        var args: [String] = ["-T"]
        if let port = transport.port {
            args += ["-p", String(port)]
        }
        if let identity = transport.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let controlPath = transport.controlPath, !controlPath.isEmpty {
            args += ["-o", "ControlPath=\(controlPath)"]
            args += ["-o", "ControlMaster=no"]
        }
        args += ["-o", "ServerAliveInterval=15"]
        args += ["-o", "ServerAliveCountMax=4"]
        args += ["-o", "BatchMode=yes"]
        args.append(transport.destination)
        // `echo $HOME` is shell-evaluated on the remote so $HOME
        // expands to the absolute path. No quoting needed because we
        // control the entire command string.
        args.append("echo $HOME")
        return args
    }

    // MARK: - Default runner (production)

    static let defaultRunner: SSHRunner = { args in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice

            proc.terminationHandler = { p in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if p.terminationStatus == 0 {
                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: stdout)
                } else {
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ResolveError.nonZeroExit(
                        code: p.terminationStatus,
                        stderr: stderr
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Internals

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw ResolveError.timeout
            }
            guard let result = try await group.next() else {
                throw ResolveError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}
