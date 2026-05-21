import Foundation

/// Public chunk model used by the Agent Inspector panel. Values are
/// agent-agnostic: both Claude and Codex transcripts are normalised to this
/// shape so the renderer doesn't care which agent produced them.
///
/// Naming and structure mirror the reference implementation in
/// `claude-devtools/src/main/types/chunks.ts` (UserChunk, AIChunk, SystemChunk,
/// CompactChunk) so any future port from the reference renderer can stay
/// straightforward.
public enum AgentChunk: Equatable, Sendable {
    case user(UserChunk)
    case ai(AIChunk)
    case system(SystemChunk)
    case compact(CompactChunk)

    public var id: String {
        switch self {
        case .user(let c): return c.id
        case .ai(let c): return c.id
        case .system(let c): return c.id
        case .compact(let c): return c.id
        }
    }

    public var startTime: Date {
        switch self {
        case .user(let c): return c.startTime
        case .ai(let c): return c.startTime
        case .system(let c): return c.startTime
        case .compact(let c): return c.startTime
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

    public init(
        id: String,
        assistantText: String,
        thinkingText: String,
        toolCalls: [AgentToolCall],
        model: String?,
        usage: AgentTokenUsage = .zero,
        startTime: Date,
        endTime: Date? = nil
    ) {
        self.id = id
        self.assistantText = assistantText
        self.thinkingText = thinkingText
        self.toolCalls = toolCalls
        self.model = model
        self.usage = usage
        self.startTime = startTime
        self.endTime = endTime
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

    public var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0 &&
            cacheReadTokens == 0 && cacheCreationTokens == 0
    }
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
