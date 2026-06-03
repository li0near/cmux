public import Foundation

/// In-memory mirror of one row in `~/.cmuxterm/<agent>-hook-sessions.json`,
/// written by the cmux CLI's hook handlers.
///
/// Schema is shared between Claude and Codex hook stores — both write
/// the same 7-field record (`sessionId`, `workspaceId`, `surfaceId`,
/// `cwd?`, `transcriptPath?`, `pid?`, `updatedAt`). Decoded fields
/// only — unknown fields are skipped so future schema additions don't
/// break the panel.
public struct AgentHookSessionRecord: Equatable, Sendable {
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
