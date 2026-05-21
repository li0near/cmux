import Foundation

/// Builds `AgentChunk` values from a stream of Codex rollout JSONL lines.
///
/// Schema: see `CodexRolloutLine`. Codex's rollout format only carries user
/// prompts and assistant text — there's no structured tool-call schema in the
/// rollout (tool calls live in a sidecar audit log). For the inspector this
/// is fine: we surface user/assistant turns plus session/turn metadata
/// captured from `session_meta` / `turn_context`.
///
/// Codex lacks per-line timestamps; we synthesise monotonic timestamps via
/// the `lineIndex` callback so callers (e.g. `CodexSyntheticTimestamps`) can
/// stamp each chunk.
struct CodexChunkBuilder {

    private(set) var chunks: [AgentChunk] = []

    /// Most recent `turn_context` payload seen — applied to the next AI chunk
    /// as its model label.
    private var pendingModel: String?

    /// In-progress AI chunk being merged across consecutive assistant
    /// `response_item`s.
    private var pendingAIChunk: PendingAIChunk?

    /// Session metadata captured for diagnostic surfaces.
    private(set) var sessionMeta: CodexSessionMeta?

    /// Synthetic timestamp generator. Caller increments per ingested line.
    var stampForIndex: (Int) -> Date = { _ in .distantPast }

    private var lineIndex = 0

    mutating func ingest(_ line: CodexRolloutLine) {
        defer { lineIndex += 1 }
        let stamp = stampForIndex(lineIndex)
        if let meta = line.sessionMeta {
            sessionMeta = meta
            return
        }
        if let ctx = line.turnContext, let m = ctx.model {
            pendingModel = m
            return
        }
        if let evt = line.eventMsg {
            handleEventMsg(evt, timestamp: stamp)
            return
        }
        if let item = line.responseItem {
            handleResponseItem(item, timestamp: stamp)
            return
        }
        // Other payload types: silently ignored (file_change, etc.).
    }

    func snapshot() -> [AgentChunk] {
        guard let pending = pendingAIChunk else { return chunks }
        return chunks + [.ai(pending.finalize())]
    }

    mutating func reset() {
        chunks.removeAll()
        pendingAIChunk = nil
        pendingModel = nil
        sessionMeta = nil
        lineIndex = 0
    }

    // MARK: - Handlers

    private mutating func handleEventMsg(_ evt: CodexEventMsg, timestamp: Date) {
        switch evt.innerType {
        case "user_message":
            // Same defensive ordering as response_item user — don't flush
            // pending AI until we have a real user message.
            guard let msg = evt.message,
                  let real = realCodexUserMessage(msg) else { return }
            flushPendingAIChunk()
            chunks.append(.user(UserChunk(
                id: "evt-\(lineIndex)",
                text: real,
                startTime: timestamp
            )))
        default:
            break
        }
    }

    private mutating func handleResponseItem(_ item: CodexResponseItem, timestamp: Date) {
        let combined = item.textBlocks
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return }
        switch item.role {
        case "user":
            // Don't flush the pending AI chunk until we know this user line
            // isn't system noise (e.g. <system-reminder>). Otherwise the AI
            // chunk gets split across what should be a single response.
            guard let real = realCodexUserMessage(combined) else { return }
            flushPendingAIChunk()
            chunks.append(.user(UserChunk(
                id: "resp-\(lineIndex)",
                text: real,
                startTime: timestamp
            )))
        case "assistant":
            if pendingAIChunk == nil {
                pendingAIChunk = PendingAIChunk(
                    id: "resp-ai-\(lineIndex)",
                    startTime: timestamp,
                    model: pendingModel
                )
            }
            if pendingAIChunk?.assistantText.isEmpty == false {
                pendingAIChunk?.assistantText.append("\n")
            }
            pendingAIChunk?.assistantText.append(combined)
        default:
            break
        }
    }

    private mutating func flushPendingAIChunk() {
        guard let pending = pendingAIChunk else { return }
        chunks.append(.ai(pending.finalize()))
        pendingAIChunk = nil
    }

    private struct PendingAIChunk {
        var id: String
        var startTime: Date
        var assistantText: String = ""
        var model: String?

        func finalize() -> AIChunk {
            AIChunk(
                id: id,
                assistantText: assistantText,
                thinkingText: "",
                toolCalls: [],
                model: model,
                startTime: startTime
            )
        }
    }

    /// Codex stuffs synthetic system reminders into `event_msg.user_message`
    /// payloads (e.g. `<system-reminder>` from the host). Those are not real
    /// user input — strip them. Mirrors the heuristic in
    /// `Sources/SessionIndexStore.swift:realCodexUserMessage(_:)`.
    private func realCodexUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Filter `<environment_context>...`, `<system-reminder>...`,
        // `<user-instructions>...` wrappers when they encompass the entire
        // message.
        let noiseWraps = ["<system-reminder>", "<environment_context>", "<user-instructions>"]
        for tag in noiseWraps {
            let close = "</" + tag.dropFirst()
            if trimmed.hasPrefix(tag) && trimmed.hasSuffix(close) {
                return nil
            }
        }
        return trimmed
    }
}
