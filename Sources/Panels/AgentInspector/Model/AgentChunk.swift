import Foundation

/// Public chunk model used by the Agent Inspector panel. Values are
/// agent-agnostic: both Claude and Codex transcripts are normalised to this
/// shape so the renderer doesn't care which agent produced them.
///
/// The four core chunk variants (`user`, `ai`, `system`, `compact`) borrow
/// naming from `claude-devtools/src/main/types/chunks.ts`. The `meta`
/// variant is cmux-specific and groups specialised renderable surfaces
/// added for full Claude JSONL correctness coverage (rewind branch links,
/// recap, PR links, slash-command pairs, skill titles, system reminders).
public enum AgentChunk: Equatable, Sendable {
    case user(UserChunk)
    case ai(AIChunk)
    case system(SystemChunk)
    case compact(CompactChunk)
    case meta(MetaChunk)

    public var id: String {
        switch self {
        case .user(let c): return c.id
        case .ai(let c): return c.id
        case .system(let c): return c.id
        case .compact(let c): return c.id
        case .meta(let c): return c.id
        }
    }

    public var startTime: Date {
        switch self {
        case .user(let c): return c.startTime
        case .ai(let c): return c.startTime
        case .system(let c): return c.startTime
        case .compact(let c): return c.startTime
        case .meta(let c): return c.startTime
        }
    }
}

public struct UserChunk: Equatable, Sendable {
    public let id: String
    /// First user message text (string content, or stringified array content).
    public let text: String
    public let startTime: Date

    public init(id: String, text: String, startTime: Date) {
        self.id = id
        self.text = text
        self.startTime = startTime
    }
}

public struct AIChunk: Equatable, Sendable {
    public let id: String
    /// Concatenated assistant text spans across the chunk's response stream.
    public let assistantText: String
    /// Concatenated thinking spans (extended thinking blocks).
    public let thinkingText: String
    /// Tool calls invoked during the chunk, in order.
    public let toolCalls: [AgentToolCall]
    /// Optional model name reported by the assistant message (e.g. "claude-sonnet-4-5").
    public let model: String?
    /// Aggregate token usage across all assistant messages folded into the
    /// chunk. Each field is the sum across messages.
    public let usage: AgentTokenUsage
    public let startTime: Date
    /// Timestamp of the last message folded into this chunk. Used to compute
    /// per-turn duration in the inspector. Nil when the chunk's source format
    /// does not carry per-line timestamps (e.g. Codex rollouts).
    public let endTime: Date?
    /// Per-turn aggregate duration sourced from Claude's `system.subtype:
    /// turn_duration` JSONL entry, when available. Authoritative source —
    /// preferred over `endTime - startTime` when present. nil for Codex,
    /// older Claude versions, or live (in-progress) chunks.
    public let perTurnDurationMs: Int?
    /// Per-turn aggregate message count from the same `turn_duration` entry.
    public let messageCount: Int?

    public init(
        id: String,
        assistantText: String,
        thinkingText: String,
        toolCalls: [AgentToolCall],
        model: String?,
        usage: AgentTokenUsage = .zero,
        startTime: Date,
        endTime: Date? = nil,
        perTurnDurationMs: Int? = nil,
        messageCount: Int? = nil
    ) {
        self.id = id
        self.assistantText = assistantText
        self.thinkingText = thinkingText
        self.toolCalls = toolCalls
        self.model = model
        self.usage = usage
        self.startTime = startTime
        self.endTime = endTime
        self.perTurnDurationMs = perTurnDurationMs
        self.messageCount = messageCount
    }
}

/// Aggregated token usage. All fields can be 0 if the JSONL didn't include
/// usage info (older entries, or non-assistant messages).
public struct AgentTokenUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    public static let zero = AgentTokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0
    )
}

public struct SystemChunk: Equatable, Sendable {
    public let id: String
    /// Trimmed command output (the inner text of `<local-command-stdout>` etc.).
    public let output: String
    public let startTime: Date

    public init(id: String, output: String, startTime: Date) {
        self.id = id
        self.output = output
        self.startTime = startTime
    }
}

public struct CompactChunk: Equatable, Sendable {
    public let id: String
    public let summary: String
    public let startTime: Date

    public init(id: String, summary: String, startTime: Date) {
        self.id = id
        self.summary = summary
        self.startTime = startTime
    }
}

// MARK: - MetaChunk

/// Specialised renderable chunks. Each variant maps to a distinct row
/// shape in `ChunkRowView` (Phase B); see `ClaudeRenderPolicy` for the
/// routing rules that produce each kind.
public enum MetaChunk: Equatable, Sendable {
    case branchLink(BranchLinkChunk)
    case recap(RecapChunk)
    case prLink(PrLinkChunk)
    case skillTitle(SkillTitleChunk)
    case slashCmdInput(SlashCmdInputChunk)
    case slashCmdOutput(SlashCmdOutputChunk)
    case localCommandCaveat(LocalCommandCaveatChunk)
    case systemReminder(SystemReminderChunk)
    case contextUsage(ContextUsageChunk)
    case continueResume(ContinueResumeMarkerChunk)

    public var id: String {
        switch self {
        case .branchLink(let c): return c.id
        case .recap(let c): return c.id
        case .prLink(let c): return c.id
        case .skillTitle(let c): return c.id
        case .slashCmdInput(let c): return c.id
        case .slashCmdOutput(let c): return c.id
        case .localCommandCaveat(let c): return c.id
        case .systemReminder(let c): return c.id
        case .contextUsage(let c): return c.id
        case .continueResume(let c): return c.id
        }
    }

    public var startTime: Date {
        switch self {
        case .branchLink(let c): return c.startTime
        case .recap(let c): return c.startTime
        case .prLink(let c): return c.startTime
        case .skillTitle(let c): return c.startTime
        case .slashCmdInput(let c): return c.startTime
        case .slashCmdOutput(let c): return c.startTime
        case .localCommandCaveat(let c): return c.startTime
        case .systemReminder(let c): return c.startTime
        case .contextUsage(let c): return c.startTime
        case .continueResume(let c): return c.startTime
        }
    }
}

/// Indented tree-style row at a divergence point in the active list.
/// Click → opens the abandoned branch's chunks in a sibling detail tab
/// (`AgentInspectorDetailContent.abandonedBranch`).
public struct BranchLinkChunk: Equatable, Sendable {
    public let id: String
    public let rewindIndex: Int
    public let totalRewinds: Int
    public let chunkCount: Int
    public let firstPromptPreview: String?
    public let startTime: Date
    /// Full chunk transcript of the abandoned subtree, built recursively
    /// by `ClaudeChunkBuilder`. Surfaced by the detail panel so the user
    /// can read the abandoned conversation in full instead of just a
    /// single prompt preview.
    public let chunks: [AgentChunk]

    public init(
        id: String,
        rewindIndex: Int,
        totalRewinds: Int,
        chunkCount: Int,
        firstPromptPreview: String?,
        startTime: Date,
        chunks: [AgentChunk] = []
    ) {
        self.id = id
        self.rewindIndex = rewindIndex
        self.totalRewinds = totalRewinds
        self.chunkCount = chunkCount
        self.firstPromptPreview = firstPromptPreview
        self.startTime = startTime
        self.chunks = chunks
    }
}

/// Recap (`system.subtype: away_summary`) — Claude Code's "you returned;
/// here's what was happening" auto-message.
public struct RecapChunk: Equatable, Sendable {
    public let id: String
    public let body: String
    public let startTime: Date

    public init(id: String, body: String, startTime: Date) {
        self.id = id
        self.body = body
        self.startTime = startTime
    }
}

/// PR-link record (`type: pr-link`). One per pr-link line in JSONL —
/// re-emits at later turns are not de-duplicated (per design discussion).
public struct PrLinkChunk: Equatable, Sendable {
    public let id: String
    public let prNumber: Int
    public let prUrl: String
    public let prRepository: String
    public let startTime: Date

    public init(
        id: String,
        prNumber: Int,
        prUrl: String,
        prRepository: String,
        startTime: Date
    ) {
        self.id = id
        self.prNumber = prNumber
        self.prUrl = prUrl
        self.prRepository = prRepository
        self.startTime = startTime
    }
}

/// Skill-invocation title (Phase B renders as clickable title that opens
/// the full skill body in a detail tab).
public struct SkillTitleChunk: Equatable, Sendable {
    public let id: String
    public let skillName: String
    public let basePath: String
    /// Full markdown body — surfaced via the detail tab.
    public let body: String
    public let startTime: Date

    public init(
        id: String,
        skillName: String,
        basePath: String,
        body: String,
        startTime: Date
    ) {
        self.id = id
        self.skillName = skillName
        self.basePath = basePath
        self.body = body
        self.startTime = startTime
    }
}

/// Slash-command input pill — `<command-name>/foo</command-name>` (or
/// the skill-flavour `<command-message>...<command-name>` ordering).
public struct SlashCmdInputChunk: Equatable, Sendable {
    public let id: String
    public let commandName: String
    public let args: String?
    public let startTime: Date

    public init(id: String, commandName: String, args: String?, startTime: Date) {
        self.id = id
        self.commandName = commandName
        self.args = args
        self.startTime = startTime
    }
}

/// Slash-command output (stdout/stderr extracted from
/// `<local-command-stdout>` / `<local-command-stderr>`).
public struct SlashCmdOutputChunk: Equatable, Sendable {
    public let id: String
    public let body: String
    public let isStderr: Bool
    public let startTime: Date

    public init(id: String, body: String, isStderr: Bool, startTime: Date) {
        self.id = id
        self.body = body
        self.isStderr = isStderr
        self.startTime = startTime
    }
}

/// `<local-command-caveat>` — the short preface that wraps slash-command
/// stdout.
public struct LocalCommandCaveatChunk: Equatable, Sendable {
    public let id: String
    public let body: String
    public let startTime: Date

    public init(id: String, body: String, startTime: Date) {
        self.id = id
        self.body = body
        self.startTime = startTime
    }
}

/// `<system-reminder>` body. Inline if short, link otherwise — Phase B's
/// snapshot decides based on cap classification.
public struct SystemReminderChunk: Equatable, Sendable {
    public let id: String
    public let body: String
    public let startTime: Date

    public init(id: String, body: String, startTime: Date) {
        self.id = id
        self.body = body
        self.startTime = startTime
    }
}

/// `## Context Usage` recap-style telemetry block (small inline snapshot
/// of context consumption).
public struct ContextUsageChunk: Equatable, Sendable {
    public let id: String
    public let body: String
    public let startTime: Date

    public init(id: String, body: String, startTime: Date) {
        self.id = id
        self.body = body
        self.startTime = startTime
    }
}

/// `Continue from where you left off.` resume marker — tiny `[resumed]`
/// badge per design discussion.
public struct ContinueResumeMarkerChunk: Equatable, Sendable {
    public let id: String
    public let startTime: Date

    public init(id: String, startTime: Date) {
        self.id = id
        self.startTime = startTime
    }
}
