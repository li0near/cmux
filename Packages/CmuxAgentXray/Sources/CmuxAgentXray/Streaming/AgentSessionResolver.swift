public import Foundation

/// A resolved Claude/Codex session linked to a specific terminal
/// surface in cmux.
public struct ResolvedAgentSession: Equatable, Sendable {
    public let agentKind: AgentKind
    public let sessionID: String
    public let workspaceID: String
    public let surfaceID: String
    public let cwd: String?
    public let transcriptPath: String?

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
        transcriptPath: String?
    ) {
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

/// Resolves a `(workspaceID, surfaceID)` pair to a live
/// `ResolvedAgentSession`.
///
/// Resolution layers, in order:
///   1. **Hook stores** — `~/.cmuxterm/{claude,codex}-hook-sessions.json`,
///      written by `cmux claude-hook session-start` and the codex
///      equivalent. Authoritative when populated.
///   2. **Claude tty fallback** — restored Claude sessions can run
///      before a fresh SessionStart hook re-scopes the hook store.
///      If exact lookup misses, inspect the focused terminal's tty
///      for `claude --resume <sessionID>` and resolve that exact
///      transcript.
///
/// Deliberately does NOT use a disk-mtime fallback. Picking the
/// freshest `.jsonl` in `~/.claude/projects/<encoded-cwd>/` cannot
/// disambiguate sibling terminals sharing a cwd.
///
/// `@unchecked Sendable` — `FileManager` and the hook stores are
/// thread-safe in practice; Apple just doesn't mark `FileManager`
/// `Sendable`.
public struct AgentSessionResolver: @unchecked Sendable {
    private let claudeStore: ClaudeHookSessionStore
    private let codexStore: CodexHookSessionStore
    private let fileManager: FileManager
    private let claudeProjectsRoot: String
    private let processCommandsForTTY: @Sendable (String) -> [(pid: Int, command: String)]

    public init(
        claudeStore: ClaudeHookSessionStore = ClaudeHookSessionStore(),
        codexStore: CodexHookSessionStore = CodexHookSessionStore(),
        fileManager: FileManager = .default,
        claudeProjectsRoot: String = AgentSessionResolver.defaultClaudeProjectsRoot,
        processCommandsForTTY: @escaping @Sendable (String) -> [(pid: Int, command: String)]
            = AgentSessionResolver.defaultProcessCommandsForTTY
    ) {
        self.claudeStore = claudeStore
        self.codexStore = codexStore
        self.fileManager = fileManager
        self.claudeProjectsRoot = claudeProjectsRoot
        self.processCommandsForTTY = processCommandsForTTY
    }

    public static var defaultClaudeProjectsRoot: String {
        NSString(string: "~/.claude/projects").expandingTildeInPath
    }

    public func resolve(
        workspaceID: String,
        surfaceID: String,
        cwdHint: String? = nil,
        ttyName: String? = nil
    ) -> ResolvedAgentSession? {
        let claude = claudeStore.record(forWorkspaceId: workspaceID, surfaceId: surfaceID)
        let codex = codexStore.record(forWorkspaceId: workspaceID, surfaceId: surfaceID)

        switch (claude, codex) {
        case (.some(let c), .some(let x)):
            if x.updatedAt > c.updatedAt {
                return makeSession(kind: .codex, record: x)
            }
            return makeSession(kind: .claude, record: c)
        case (.some(let c), .none):
            return makeSession(kind: .claude, record: c)
        case (.none, .some(let x)):
            return makeSession(kind: .codex, record: x)
        case (.none, .none):
            return fallbackClaudeResumeForTTY(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                cwdHint: cwdHint,
                ttyName: ttyName
            )
        }
    }

    private func makeSession(
        kind: ResolvedAgentSession.AgentKind,
        record: AgentHookSessionRecord
    ) -> ResolvedAgentSession {
        ResolvedAgentSession(
            agentKind: kind,
            sessionID: record.sessionId,
            workspaceID: record.workspaceId,
            surfaceID: record.surfaceId,
            cwd: record.cwd,
            transcriptPath: record.transcriptPath
        )
    }

    private func fallbackClaudeResumeForTTY(
        workspaceID: String,
        surfaceID: String,
        cwdHint: String?,
        ttyName: String?
    ) -> ResolvedAgentSession? {
        guard let normalizedTTY = Self.normalizedTTYName(ttyName) else { return nil }
        guard let sessionID = processCommandsForTTY(normalizedTTY)
            .compactMap({ Self.claudeResumeSessionId(command: $0.command) })
            .last else { return nil }

        return .init(
            agentKind: .claude,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            cwd: cwdHint,
            transcriptPath: claudeTranscriptPath(sessionID: sessionID, cwdHint: cwdHint)
        )
    }

    private func claudeTranscriptPath(sessionID: String, cwdHint: String?) -> String? {
        guard Self.claudeSessionIdIsSafeFilename(sessionID) else { return nil }
        if let cwd = cwdHint?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let projectDir = Self.encodeClaudeProjectDir((cwd as NSString).standardizingPath)
            let path = URL(fileURLWithPath: claudeProjectsRoot, isDirectory: true)
                .appendingPathComponent(projectDir, isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
                .path
            if fileManager.fileExists(atPath: path) { return path }
        }
        guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: claudeProjectsRoot)
            else { return nil }
        for projectDir in projectDirs {
            let path = URL(fileURLWithPath: claudeProjectsRoot, isDirectory: true)
                .appendingPathComponent(projectDir, isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
                .path
            if fileManager.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func claudeResumeSessionId(command: String) -> String? {
        let parts = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.contains(where: { $0 == "claude" || $0.hasSuffix("/claude") }) else {
            return nil
        }
        for (index, part) in parts.enumerated() {
            if part == "--resume", index + 1 < parts.count {
                return safeSessionId(parts[index + 1])
            }
            if part.hasPrefix("--resume=") {
                return safeSessionId(String(part.dropFirst("--resume=".count)))
            }
        }
        return nil
    }

    private static func safeSessionId(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        return claudeSessionIdIsSafeFilename(trimmed) ? trimmed : nil
    }

    private static func claudeSessionIdIsSafeFilename(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionID != "." && sessionID != ".." &&
            sessionID.range(of: #"[\\/]"#, options: .regularExpression) == nil
    }

    private static func encodeClaudeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    private static func normalizedTTYName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
            else { return nil }
        let components = raw.split(separator: "/")
        if let last = components.last, !last.isEmpty { return String(last) }
        return raw
    }

    public static let defaultProcessCommandsForTTY: @Sendable (String) -> [(pid: Int, command: String)] = { ttyName in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard pieces.count == 2, let pid = Int(pieces[0]) else { return nil }
            return (pid: pid, command: String(pieces[1]))
        }
    }
}
