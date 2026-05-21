import Foundation

/// Builds `AgentChunk` values from a stream of raw Claude JSONL lines.
///
/// Mirrors the classification logic from
/// `claude-devtools/src/main/services/parsing/MessageClassifier.ts` and
/// `analysis/ChunkBuilder.ts`:
///
/// - `user` lines with `isMeta != true` and string content (or array content
///   that's actual user input) start a `UserChunk`.
/// - `user` lines whose content is `<local-command-stdout>...` start a
///   `SystemChunk`.
/// - `user` lines with `isMeta = true` (tool results) attach to the current
///   `AIChunk` (matched by `tool_use_id`).
/// - `assistant` lines fold into the current `AIChunk` (text + thinking +
///   tool_use blocks).
/// - Lines with `isCompactSummary = true` start a `CompactChunk`.
/// - `system`, `summary`, `file-history-snapshot`, `queue-operation`, and
///   user lines that contain only system metadata tags are filtered out
///   ("hard noise").
///
/// The builder is incremental: callers feed lines as they arrive and pull a
/// fresh chunk array out via `snapshot()`. This is important for live tailing
/// where new lines append continuously.
struct ClaudeChunkBuilder {

    // MARK: - Tag constants

    private static let localCommandStdoutTag = "<local-command-stdout>"
    private static let localCommandStderrTag = "<local-command-stderr>"
    private static let localCommandCaveatTag = "<local-command-caveat>"
    private static let systemReminderTag = "<system-reminder>"

    private static let systemOutputTags: [String] = [
        localCommandStdoutTag,
        localCommandStderrTag,
        localCommandCaveatTag,
        systemReminderTag,
    ]

    private static let hardNoiseTags: [String] = [
        localCommandCaveatTag,
        systemReminderTag,
    ]

    private static let emptyStdout = "<local-command-stdout></local-command-stdout>"
    private static let emptyStderr = "<local-command-stderr></local-command-stderr>"

    // MARK: - State

    /// Already-finalised chunks.
    private(set) var chunks: [AgentChunk] = []

    /// In-progress AI chunk being built. Flushed when a non-AI line arrives or
    /// when `snapshot()` is requested.
    private struct PendingAIChunk {
        var id: String
        var startTime: Date
        var lastTimestamp: Date?
        var assistantText: String = ""
        var thinkingText: String = ""
        var toolCalls: [String: AgentToolCall] = [:]
        var toolCallOrder: [String] = []
        /// Timestamp of the `tool_use` entry per tool id. Used to compute
        /// `durationMs` when the matching `tool_result` arrives.
        var toolStartedAt: [String: Date] = [:]
        var model: String?
        var usage: AgentTokenUsage = .zero

        func finalize() -> AIChunk {
            AIChunk(
                id: id,
                assistantText: assistantText,
                thinkingText: thinkingText,
                toolCalls: toolCallOrder.compactMap { toolCalls[$0] },
                model: model,
                usage: usage,
                startTime: startTime,
                endTime: lastTimestamp
            )
        }
    }

    private var pendingAIChunk: PendingAIChunk?

    // MARK: - API

    /// Feed a single decoded JSONL line. Order matters — the file's natural
    /// order is the conversation order.
    mutating func ingest(_ line: ClaudeJSONLLine) {
        let category = classify(line)
        switch category {
        case .hardNoise:
            return
        case .compact:
            flushPendingAIChunk()
            chunks.append(.compact(buildCompactChunk(from: line)))
        case .user:
            flushPendingAIChunk()
            if let chunk = buildUserChunk(from: line) {
                chunks.append(.user(chunk))
            }
        case .system:
            flushPendingAIChunk()
            if let chunk = buildSystemChunk(from: line) {
                chunks.append(.system(chunk))
            }
        case .ai:
            mergeIntoPendingAIChunk(line)
        }
    }

    /// Returns a snapshot of all chunks built so far, including any pending
    /// AI chunk flushed for display purposes. Call this whenever the UI needs
    /// to refresh.
    func snapshot() -> [AgentChunk] {
        guard let pending = pendingAIChunk else { return chunks }
        return chunks + [.ai(pending.finalize())]
    }

    /// Clears all state. Used when the underlying file rotates.
    mutating func reset() {
        chunks.removeAll()
        pendingAIChunk = nil
    }

    // MARK: - Classification

    enum Category: Equatable {
        case user
        case system
        case ai
        case compact
        case hardNoise
    }

    func classify(_ line: ClaudeJSONLLine) -> Category {
        // Hard-noise types
        switch line.type {
        case "system", "summary", "file-history-snapshot", "queue-operation":
            return .hardNoise
        default:
            break
        }

        // Compact summary marker
        if line.isCompactSummary == true {
            return .compact
        }

        // Synthetic assistant messages (placeholders)
        if line.type == "assistant", line.message?.model == "<synthetic>" {
            return .hardNoise
        }

        // User entries: route into user / system / hardNoise / ai
        if line.type == "user" {
            return classifyUserLine(line)
        }

        // Assistant lines that survived hard-noise checks → ai bucket
        if line.type == "assistant" {
            return .ai
        }

        // Unknown line types fall through as hard noise so we never crash on
        // a future Claude format change.
        return .hardNoise
    }

    private func classifyUserLine(_ line: ClaudeJSONLLine) -> Category {
        // Internal meta user lines (tool results) are AI flow, not standalone.
        if line.isMeta == true {
            return .ai
        }

        guard let content = line.message?.content else {
            return .hardNoise
        }

        switch content {
        case .text(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .hardNoise }

            // Empty command stdout/stderr → hard noise.
            if trimmed == Self.emptyStdout || trimmed == Self.emptyStderr {
                return .hardNoise
            }

            // System command output → SystemChunk.
            if trimmed.hasPrefix(Self.localCommandStdoutTag)
                || trimmed.hasPrefix(Self.localCommandStderrTag) {
                return .system
            }

            // Lines wrapped entirely in a noise tag → hard noise.
            for tag in Self.hardNoiseTags {
                let close = "</" + tag.dropFirst()  // <foo> → </foo>
                if trimmed.hasPrefix(tag) && trimmed.hasSuffix(close) {
                    return .hardNoise
                }
            }

            // Interruption messages are part of AI flow.
            if trimmed.hasPrefix("[Request interrupted by user") {
                return .ai
            }

            // Any other system-output prefix → not user input; skip it.
            for tag in Self.systemOutputTags {
                if trimmed.hasPrefix(tag) {
                    return .hardNoise
                }
            }

            return .user

        case .blocks(let blocks):
            // Single-block interruption → AI flow.
            if blocks.count == 1,
               let only = blocks.first,
               only.type == "text",
               only.text?.hasPrefix("[Request interrupted by user") == true {
                return .ai
            }

            // System command stdout block → SystemChunk.
            if blocks.contains(where: {
                $0.type == "text"
                    && ($0.text?.hasPrefix(Self.localCommandStdoutTag) == true)
            }) {
                return .system
            }

            // Any tool_result blocks → AI flow.
            if blocks.contains(where: { $0.type == "tool_result" }) {
                return .ai
            }

            // Real user content (text/image) without noise prefixes.
            let hasUserContent = blocks.contains {
                $0.type == "text" || $0.type == "image"
            }
            guard hasUserContent else { return .hardNoise }

            for block in blocks where block.type == "text" {
                guard let text = block.text else { continue }
                for tag in Self.systemOutputTags {
                    if text.hasPrefix(tag) { return .hardNoise }
                }
            }

            return .user
        }
    }

    // MARK: - Chunk builders

    private func buildUserChunk(from line: ClaudeJSONLLine) -> UserChunk? {
        guard let content = line.message?.content else { return nil }
        let text: String
        switch content {
        case .text(let str):
            text = str.trimmingCharacters(in: .whitespacesAndNewlines)
        case .blocks(let blocks):
            text = blocks
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return UserChunk(
            id: line.stableId,
            text: text,
            startTime: line.timestamp ?? .distantPast
        )
    }

    private func buildSystemChunk(from line: ClaudeJSONLLine) -> SystemChunk? {
        guard let content = line.message?.content else { return nil }
        let raw: String
        switch content {
        case .text(let str):
            raw = str
        case .blocks(let blocks):
            raw = blocks.compactMap { $0.text }.joined(separator: "\n")
        }
        return SystemChunk(
            id: line.stableId,
            output: stripCommandOutputTags(raw),
            startTime: line.timestamp ?? .distantPast
        )
    }

    private func buildCompactChunk(from line: ClaudeJSONLLine) -> CompactChunk {
        let summary = line.summary
            ?? extractTextContent(from: line.message?.content)
            ?? ""
        return CompactChunk(
            id: line.stableId,
            summary: summary,
            startTime: line.timestamp ?? .distantPast
        )
    }

    // MARK: - AI chunk merging

    private mutating func mergeIntoPendingAIChunk(_ line: ClaudeJSONLLine) {
        if pendingAIChunk == nil {
            pendingAIChunk = PendingAIChunk(
                id: line.stableId,
                startTime: line.timestamp ?? .distantPast
            )
        }

        if let ts = line.timestamp {
            pendingAIChunk?.lastTimestamp = ts
        }

        guard let content = line.message?.content else { return }
        if let model = line.message?.model, pendingAIChunk?.model == nil {
            pendingAIChunk?.model = model
        }
        if let usage = line.message?.usage {
            pendingAIChunk?.usage.inputTokens += usage.inputTokens ?? 0
            pendingAIChunk?.usage.outputTokens += usage.outputTokens ?? 0
            pendingAIChunk?.usage.cacheReadTokens += usage.cacheReadInputTokens ?? 0
            pendingAIChunk?.usage.cacheCreationTokens += usage.cacheCreationInputTokens ?? 0
        }

        switch content {
        case .text(let str):
            // Interruption text from a user line (isMeta could be either).
            // Append as assistantText with a clear marker so it's still visible.
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendAssistantText(trimmed)
            }
        case .blocks(let blocks):
            for block in blocks {
                switch block.type {
                case "text":
                    if let t = block.text {
                        appendAssistantText(t)
                    }
                case "thinking":
                    if let t = block.thinking {
                        appendThinkingText(t)
                    }
                case "tool_use":
                    appendToolUse(block, timestamp: line.timestamp)
                case "tool_result":
                    attachToolResult(block, timestamp: line.timestamp)
                case "image":
                    appendAssistantText("[image]")
                default:
                    break
                }
            }
        }
    }

    private mutating func appendAssistantText(_ text: String) {
        guard pendingAIChunk != nil else { return }
        if !pendingAIChunk!.assistantText.isEmpty {
            pendingAIChunk!.assistantText.append("\n")
        }
        pendingAIChunk!.assistantText.append(text)
    }

    private mutating func appendThinkingText(_ text: String) {
        guard pendingAIChunk != nil else { return }
        if !pendingAIChunk!.thinkingText.isEmpty {
            pendingAIChunk!.thinkingText.append("\n")
        }
        pendingAIChunk!.thinkingText.append(text)
    }

    private mutating func appendToolUse(_ block: ClaudeContentBlock, timestamp: Date?) {
        guard let id = block.id, let name = block.name else { return }
        let teamMemberName = ClaudeChunkBuilder.extractTeamMemberName(name: name, input: block.input)
        let teamName = ClaudeChunkBuilder.extractTeamName(name: name, input: block.input)
        let call = AgentToolCall(
            id: id,
            name: name,
            summary: ClaudeChunkBuilder.summarizeToolInput(name: name, input: block.input),
            inputDetail: ClaudeChunkBuilder.formatToolInput(block.input),
            result: nil,
            isError: false,
            subagentType: ClaudeChunkBuilder.extractSubagentType(name: name, input: block.input),
            teamMemberName: teamMemberName,
            teamName: teamName,
            durationMs: nil
        )
        if pendingAIChunk?.toolCalls[id] == nil {
            pendingAIChunk?.toolCallOrder.append(id)
        }
        pendingAIChunk?.toolCalls[id] = call
        if let timestamp {
            pendingAIChunk?.toolStartedAt[id] = timestamp
        }
    }

    private mutating func attachToolResult(_ block: ClaudeContentBlock, timestamp: Date?) {
        guard let id = block.toolUseId else { return }
        let body = ClaudeChunkBuilder.flattenToolResult(block.toolResultContent)
        let durationMs: Int? = {
            guard let timestamp,
                  let started = pendingAIChunk?.toolStartedAt[id] else { return nil }
            let delta = timestamp.timeIntervalSince(started)
            return delta >= 0 ? Int(delta * 1000) : nil
        }()
        if let existing = pendingAIChunk?.toolCalls[id] {
            pendingAIChunk?.toolCalls[id] = AgentToolCall(
                id: existing.id,
                name: existing.name,
                summary: existing.summary,
                inputDetail: existing.inputDetail,
                result: body,
                isError: block.isError ?? false,
                subagentType: existing.subagentType,
                teamMemberName: existing.teamMemberName,
                teamName: existing.teamName,
                durationMs: durationMs
            )
        } else {
            // Tool result without preceding tool_use (shouldn't happen, but be
            // defensive). Surface as a synthetic call so it isn't lost.
            let synthetic = AgentToolCall(
                id: id,
                name: "(tool result)",
                summary: "",
                inputDetail: "",
                result: body,
                isError: block.isError ?? false,
                subagentType: nil,
                teamMemberName: nil,
                teamName: nil,
                durationMs: durationMs
            )
            if pendingAIChunk?.toolCalls[id] == nil {
                pendingAIChunk?.toolCallOrder.append(id)
            }
            pendingAIChunk?.toolCalls[id] = synthetic
        }
    }

    private mutating func flushPendingAIChunk() {
        guard let pending = pendingAIChunk else { return }
        chunks.append(.ai(pending.finalize()))
        pendingAIChunk = nil
    }

    // MARK: - Helpers

    private func stripCommandOutputTags(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in [Self.localCommandStdoutTag, Self.localCommandStderrTag] {
            let close = "</" + tag.dropFirst()
            if s.hasPrefix(tag) && s.hasSuffix(close) {
                s = String(s.dropFirst(tag.count).dropLast(close.count))
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTextContent(from content: ClaudeMessageContent?) -> String? {
        guard let content else { return nil }
        switch content {
        case .text(let s): return s
        case .blocks(let arr):
            return arr.compactMap { $0.text }.joined(separator: "\n")
        }
    }

    /// Build a compact one-line summary for a tool call given its raw input.
    /// We surface only the most user-relevant field per tool. Keep this light
    /// — full input is preserved in the raw transcript if needed.
    static func summarizeToolInput(name: String, input: ClaudeJSONValue?) -> String {
        guard let input else { return "" }
        guard case .object(let obj) = input else { return input.displayString }

        switch name {
        case "Read", "Edit", "Write", "MultiEdit":
            if case .string(let path)? = obj["file_path"] {
                return path
            }
        case "Bash":
            if case .string(let cmd)? = obj["command"] {
                return truncated(cmd, max: 120)
            }
        case "Grep", "Glob":
            if case .string(let pat)? = obj["pattern"] {
                return pat
            }
        case "Task":
            if case .string(let desc)? = obj["description"] {
                return desc
            }
            if case .string(let prompt)? = obj["prompt"] {
                return truncated(prompt, max: 120)
            }
        case "WebFetch", "WebSearch":
            if case .string(let url)? = obj["url"] ?? obj["query"] {
                return url
            }
        default:
            break
        }
        // Fallback: stringify the first entry deterministically.
        return obj
            .map { "\($0.key)=\($0.value.displayString)" }
            .sorted()
            .first
            ?? ""
    }

    static func flattenToolResult(_ value: ClaudeJSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .array(let arr):
            // Tool results can be `[{ type: "text", text: "..." }, ...]`.
            return arr.compactMap { item -> String? in
                if case .object(let obj) = item,
                   case .string(let s)? = obj["text"] {
                    return s
                }
                return nil
            }
            .joined(separator: "\n")
        default:
            return value.displayString
        }
    }

    /// Pretty-print a tool's input as a multi-line, key/value layout. Each
    /// top-level field is on its own line so the renderer can show e.g.
    ///   command: ls -la
    ///   timeout: 30000
    /// for a Bash invocation. Long values are truncated.
    static func formatToolInput(_ input: ClaudeJSONValue?) -> String {
        guard let input else { return "" }
        guard case .object(let obj) = input else { return input.displayString }
        let keys = obj.keys.sorted()
        var lines: [String] = []
        for key in keys {
            guard let value = obj[key] else { continue }
            let rendered: String
            switch value {
            case .string(let s):
                rendered = truncated(s, max: 1000)
            case .null, .bool, .int, .double:
                rendered = value.displayString
            case .array, .object:
                // Compact JSON-ish for nested values; truncate.
                rendered = truncated(value.displayString, max: 400)
            }
            lines.append("\(key): \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

    /// For Task tools, the subagent type is in the `subagent_type` input
    /// field (Claude Code's spec). Return nil for non-Task tools.
    static func extractSubagentType(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["subagent_type"] else {
            return nil
        }
        return s
    }

    /// For Task tools that target a configured Claude Code team member, the
    /// Task input carries a `name` field (e.g. "Alice"). Mirrors
    /// claude-devtools' extraction at `SubagentResolver.ts:322-326`.
    static func extractTeamMemberName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["name"] else {
            return nil
        }
        return s
    }

    /// For Task tools that target a team member, the input also carries a
    /// `team_name` field (e.g. "engineering"). Mirrors claude-devtools.
    static func extractTeamName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["team_name"] else {
            return nil
        }
        return s
    }

    private static func truncated(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
