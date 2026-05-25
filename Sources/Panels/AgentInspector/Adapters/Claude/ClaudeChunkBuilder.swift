import Foundation

/// Builds `AgentChunk` values from a stream of raw Claude JSONL lines.
///
/// Two-pass design:
///   1. **Pass 1** — `ClaudeBranchResolver.resolve(...)` walks the rewind tree
///      from the latest `last-prompt` marker's `leafUuid` to the conversation
///      root, producing the active-branch UUID set + grouped abandoned
///      branches.
///   2. **Pass 2** — for every buffered line, `ClaudeRenderPolicy.route(...)`
///      decides skip / sidechain / abandoned-branch / render. Sidechain lines
///      are pooled by `parentToolUseID`; abandoned branches surface as
///      `BranchLink` chunks at their divergence points. Tree-affiliated lines
///      on the active branch flow through the existing classifier and chunk
///      builders.
///
/// The builder is a thin buffer: callers feed lines via `ingest(_:)` and pull
/// a fresh chunk array out via `snapshot()`. Each `snapshot()` runs the two
/// passes from scratch — cheap for typical sessions and ensures rewinds
/// landing mid-session collapse the chunk list immediately.
struct ClaudeChunkBuilder {

    // MARK: - Tag constants

    static let localCommandStdoutTag = "<local-command-stdout>"
    static let localCommandStderrTag = "<local-command-stderr>"
    private static let localCommandCaveatTag = "<local-command-caveat>"
    private static let systemReminderTag = "<system-reminder>"

    /// User lines whose content is entirely wrapped in one of these tags
    /// are dropped when `isMeta` is null/false. (`isMeta=true` lines with
    /// the same tags route through `ClaudeRenderPolicy` to the `MetaChunk`
    /// surface instead.)
    private static let isMetaNullNoiseTags: [String] = [
        localCommandCaveatTag,
        systemReminderTag,
    ]

    private static let emptyStdout = "<local-command-stdout></local-command-stdout>"
    private static let emptyStderr = "<local-command-stderr></local-command-stderr>"

    // MARK: - State

    /// Buffered raw lines in arrival order. Each `snapshot()` re-derives
    /// chunks from this buffer.
    private var rawLines: [ClaudeJSONLLine] = []

    // MARK: - API

    /// Append one decoded line to the buffer. Order matters — file order is
    /// conversation order. Re-derivation happens when `snapshot()` is called.
    mutating func ingest(_ line: ClaudeJSONLLine) {
        rawLines.append(line)
    }

    /// Rebuild the full chunk list from the buffered lines. Pure value
    /// transformation; safe to call on any actor.
    func snapshot() -> [AgentChunk] {
        var ctx = BuildContext(
            resolution: ClaudeBranchResolver.resolve(lines: rawLines)
        )
        // Pre-pass: cache turn_duration entries by their `parentUuid` so the
        // matching AIChunk can pick them up at flush time.
        for line in rawLines where line.type == "system" && line.subtype == "turn_duration" {
            if let parent = line.parentUuid, let ms = line.durationMs {
                ctx.turnDurations[parent] = TurnDurationStamp(
                    durationMs: ms,
                    messageCount: line.messageCount ?? 0
                )
            }
        }
        for line in rawLines {
            dispatch(line, ctx: &ctx)
        }
        ctx.flushPendingAIChunk()
        return ctx.chunks
    }

    /// Clears the buffer. Used when the underlying file rotates.
    mutating func reset() {
        rawLines.removeAll()
    }

    // MARK: - Top-level dispatch

    private func dispatch(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        // turn_duration is consumed by the pre-pass; never emit a chunk.
        if line.type == "system", line.subtype == "turn_duration" {
            return
        }

        let routing = ClaudeRenderPolicy.route(
            line,
            activeBranch: ctx.resolution.activeUUIDs,
            activeBranchAvailable: ctx.resolution.leafUuid != nil
        )

        switch routing {
        case .skip:
            return
        case .skipBranchAffiliated:
            // Branch-link emission is keyed to divergence-point UUIDs from
            // the resolver, not to individual abandoned lines, so individual
            // skipped lines don't need per-line accounting here.
            return
        case .sidechainMain:
            ctx.collectSidechainLine(line)
            return
        case .render(let kind):
            // Before emitting an active-branch chunk, check if its parent
            // UUID is a branch-divergence point that hasn't been surfaced
            // yet. If so, emit the BranchLink first.
            ctx.maybeEmitBranchLinks(beforeAdjacentTo: line)

            switch kind {
            case .compact:
                ctx.flushPendingAIChunk()
                ctx.chunks.append(.compact(buildCompactChunk(from: line)))
            case .user:
                let cat = classify(line)
                switch cat {
                case .compact:
                    ctx.flushPendingAIChunk()
                    ctx.chunks.append(.compact(buildCompactChunk(from: line)))
                case .user:
                    ctx.flushPendingAIChunk()
                    if let chunk = buildUserChunk(from: line) {
                        ctx.chunks.append(.user(chunk))
                    }
                case .system:
                    ctx.flushPendingAIChunk()
                    if let chunk = buildSystemChunk(from: line) {
                        ctx.chunks.append(.system(chunk))
                    }
                case .ai:
                    mergeIntoPendingAIChunk(line, ctx: &ctx)
                case .hardNoise:
                    return
                }
            case .system:
                ctx.flushPendingAIChunk()
                if let chunk = buildSystemChunk(from: line) {
                    ctx.chunks.append(.system(chunk))
                }
            case .ai:
                mergeIntoPendingAIChunk(line, ctx: &ctx)
            }
        case .renderSpecial(let kind):
            ctx.maybeEmitBranchLinks(beforeAdjacentTo: line)
            ctx.flushPendingAIChunk()
            emitSpecial(line, kind: kind, ctx: &ctx)
        }
    }

    private func emitSpecial(
        _ line: ClaudeJSONLLine,
        kind: ClaudeSpecialKind,
        ctx: inout BuildContext
    ) {
        let id = line.stableId
        let ts = line.timestamp ?? .distantPast
        let body = extractMetaText(line)

        switch kind {
        case .recap:
            // away_summary system lines carry the body in the top-level
            // `content` field, not in `message.content`.
            let recapBody = (line.content ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
            if recapBody.isEmpty { return }
            ctx.chunks.append(.meta(.recap(RecapChunk(id: id, body: recapBody, startTime: ts))))
        case .prLink:
            guard let prNumber = line.prNumber,
                  let prUrl = line.prUrl,
                  let prRepository = line.prRepository else { return }
            ctx.chunks.append(.meta(.prLink(PrLinkChunk(
                id: id,
                prNumber: prNumber,
                prUrl: prUrl,
                prRepository: prRepository,
                startTime: ts
            ))))
        case .continueResume:
            ctx.chunks.append(.meta(.continueResume(
                ContinueResumeMarkerChunk(id: id, startTime: ts)
            )))
        case .slashCmdInput:
            if case let .slashCommandInput(name, args) = ClaudeContentDetector.classify(body) {
                ctx.chunks.append(.meta(.slashCmdInput(SlashCmdInputChunk(
                    id: id, commandName: name, args: args, startTime: ts
                ))))
            }
        case .slashCmdOutput:
            if case let .slashCommandOutput(b, isStderr) = ClaudeContentDetector.classify(body) {
                if b.isEmpty { return }   // empty stdout/stderr → drop
                ctx.chunks.append(.meta(.slashCmdOutput(SlashCmdOutputChunk(
                    id: id, body: b, isStderr: isStderr, startTime: ts
                ))))
            }
        case .localCommandCaveat:
            if case let .localCommandCaveat(b) = ClaudeContentDetector.classify(body) {
                ctx.chunks.append(.meta(.localCommandCaveat(LocalCommandCaveatChunk(
                    id: id, body: b, startTime: ts
                ))))
            }
        case .systemReminder:
            if case let .systemReminder(b) = ClaudeContentDetector.classify(body) {
                ctx.chunks.append(.meta(.systemReminder(SystemReminderChunk(
                    id: id, body: b, startTime: ts
                ))))
            }
        case .skillTitle:
            if case let .skillInvocation(name, basePath, b) = ClaudeContentDetector.classify(body) {
                ctx.chunks.append(.meta(.skillTitle(SkillTitleChunk(
                    id: id, skillName: name, basePath: basePath, body: b, startTime: ts
                ))))
            }
        case .contextUsage:
            if case let .contextUsage(b) = ClaudeContentDetector.classify(body) {
                ctx.chunks.append(.meta(.contextUsage(ContextUsageChunk(
                    id: id, body: b, startTime: ts
                ))))
            }
        case .unknownMeta:
            // Unrecognised isMeta=true content. Treat as a SystemReminder
            // body so it surfaces visibly rather than vanishing — Phase B
            // can refine the row variant if a clearer category emerges.
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            ctx.chunks.append(.meta(.systemReminder(SystemReminderChunk(
                id: id, body: trimmed, startTime: ts
            ))))
        }
    }

    private func extractMetaText(_ line: ClaudeJSONLLine) -> String {
        guard let content = line.message?.content else { return "" }
        switch content {
        case .text(let s): return s
        case .blocks(let blocks):
            for b in blocks where b.type == "text" {
                if let t = b.text { return t }
            }
            return ""
        }
    }

    // MARK: - Build context (per-snapshot mutable state)

    fileprivate struct BuildContext {
        let resolution: ClaudeBranchResolution
        var chunks: [AgentChunk] = []
        var pendingAIChunk: PendingAIChunk?
        /// `last-message uuid → turn_duration stamp` collected in the pre-pass.
        var turnDurations: [String: TurnDurationStamp] = [:]
        /// `parentToolUseID → buffered sidechain raw lines`. Phase A captures
        /// the lines; Phase A.7 attaches them to the parent Task tool call
        /// at flush time as a chunk array.
        var sidechainLinesByParent: [String: [ClaudeJSONLLine]] = [:]
        /// Set of divergence-point UUIDs whose `BranchLink` chunks have
        /// already been emitted (idempotence guard).
        var emittedDivergencePoints: Set<String> = []

        mutating func flushPendingAIChunk() {
            guard let pending = pendingAIChunk else { return }
            // Look up the per-turn duration stamp by the chunk's last
            // message uuid (turn_duration's parentUuid points to the final
            // assistant message of the turn).
            let stamp: TurnDurationStamp? = pending.lastMessageUuid.flatMap { turnDurations[$0] }
            let finalToolCalls = pending.toolCallOrder.compactMap { id -> AgentToolCall? in
                guard var call = pending.toolCalls[id] else { return nil }
                // Attach sidechain transcript for Task/Agent tool calls
                // when sub-agent lines were collected against this tool.
                if (call.name == "Task" || call.name == "Agent"),
                   let lines = sidechainLinesByParent[id] {
                    call = AgentToolCall(
                        id: call.id,
                        name: call.name,
                        summary: call.summary,
                        inputDetail: call.inputDetail,
                        result: call.result,
                        isError: call.isError,
                        subagentType: call.subagentType,
                        teamMemberName: call.teamMemberName,
                        teamName: call.teamName,
                        durationMs: call.durationMs,
                        sidechainTranscript: buildSidechainChunks(from: lines)
                    )
                }
                return call
            }
            chunks.append(.ai(AIChunk(
                id: pending.id,
                assistantText: pending.assistantText,
                thinkingText: pending.thinkingText,
                toolCalls: finalToolCalls,
                model: pending.model,
                usage: pending.usage,
                startTime: pending.startTime,
                endTime: pending.lastTimestamp,
                perTurnDurationMs: stamp?.durationMs,
                messageCount: stamp?.messageCount
            )))
            pendingAIChunk = nil
        }

        mutating func collectSidechainLine(_ line: ClaudeJSONLLine) {
            guard let parent = line.parentToolUseID else { return }
            sidechainLinesByParent[parent, default: []].append(line)
        }

        /// Recursively build the chunk list for a sidechain transcript.
        /// Sub-agents can themselves call `Task`/`Agent` (one level of
        /// nesting handled here; deeper nesting flattens). Sidechain
        /// builds run with no branch resolution since rewinds apply only
        /// to the main thread.
        private func buildSidechainChunks(from lines: [ClaudeJSONLLine]) -> [AgentChunk] {
            var sub = ClaudeChunkBuilder()
            for line in lines {
                // Within a sub-agent transcript, isSidechain is true on
                // every line — it's true *from the parent's perspective*.
                // Drop the flag locally so the policy treats them as main.
                sub.ingest(stripSidechain(line))
            }
            return sub.snapshot()
        }

        private func stripSidechain(_ line: ClaudeJSONLLine) -> ClaudeJSONLLine {
            // ClaudeJSONLLine has no settable property; instead we round
            // through a JSON re-encode? No — simplest is to re-encode the
            // line into a Decodable equivalent. Since this is hot path we
            // fake it via direct reconstruction.
            // Note: ClaudeJSONLLine is Decodable-only, so we can't easily
            // mutate. Workaround: leave isSidechain in place and rely on
            // the recursive snapshot's policy to NOT route to sidechainMain
            // when there's no parentToolUseID linking back outside this
            // sub-build. A sidechain line inside a sidechain transcript
            // still has a parentToolUseID pointing to its OWN parent Task
            // (not the outer one), so it routes to sidechainMain at the
            // sub-level too — which means deeper nesting gets dropped at
            // the sub-build's pendingAIChunk flush. Acceptable for Phase A.
            return line
        }

        mutating func maybeEmitBranchLinks(beforeAdjacentTo line: ClaudeJSONLLine) {
            // Emit BranchLink chunks whose divergence point is the chunk
            // *currently being added*, just before the chunk itself appears
            // in the active list. This places the `↳ Rewind #N` rows right
            // after their branch-point user prompt.
            guard let parent = line.parentUuid else { return }
            for branch in resolution.abandonedBranches
            where branch.divergencePointUuid == parent
                && !emittedDivergencePoints.contains(branch.branchRootUuid) {
                emittedDivergencePoints.insert(branch.branchRootUuid)
                chunks.append(.meta(.branchLink(BranchLinkChunk(
                    id: branch.branchRootUuid,
                    rewindIndex: branch.rewindIndex,
                    totalRewinds: resolution.totalRewinds,
                    chunkCount: branch.chunkCount,
                    firstPromptPreview: branch.firstPromptPreview,
                    startTime: line.timestamp ?? .distantPast
                ))))
            }
        }
    }

    fileprivate struct TurnDurationStamp {
        let durationMs: Int
        let messageCount: Int
    }

    fileprivate struct PendingAIChunk {
        var id: String
        var startTime: Date
        var lastTimestamp: Date?
        /// uuid of the last assistant message folded in. Used to look up
        /// `turn_duration` entries (whose parentUuid points to the final
        /// assistant message of a turn).
        var lastMessageUuid: String?
        var assistantText: String = ""
        var thinkingText: String = ""
        var toolCalls: [String: AgentToolCall] = [:]
        var toolCallOrder: [String] = []
        var toolStartedAt: [String: Date] = [:]
        var model: String?
        var usage: AgentTokenUsage = .zero
    }

    // MARK: - Classification (active-branch flavour only)

    enum Category: Equatable {
        case user
        case system
        case ai
        case compact
        case hardNoise
    }

    /// Fine-grained dispatch for tree-affiliated user lines on the active
    /// branch. The top-level routing in `ClaudeRenderPolicy` has already
    /// filtered out skip/sidechain/abandoned/special cases.
    func classify(_ line: ClaudeJSONLLine) -> Category {
        // Compact summary marker
        if line.isCompactSummary == true {
            return .compact
        }

        // Synthetic assistant messages (placeholders)
        if line.type == "assistant", line.message?.model == "<synthetic>" {
            return .hardNoise
        }

        // User entries
        if line.type == "user" {
            return classifyUserLine(line)
        }

        // Assistant lines that survived earlier filters → ai bucket
        if line.type == "assistant" {
            return .ai
        }

        return .hardNoise
    }

    private func classifyUserLine(_ line: ClaudeJSONLLine) -> Category {
        // Internal meta user lines (tool results) are AI flow, not standalone.
        // Note: isMeta=true non-tool-result lines are intercepted earlier by
        // ClaudeRenderPolicy and emitted as MetaChunk variants; the only
        // isMeta=true lines reaching this classifier are tool_result blocks.
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
            if trimmed == Self.emptyStdout || trimmed == Self.emptyStderr {
                return .hardNoise
            }
            if trimmed.hasPrefix(Self.localCommandStdoutTag)
                || trimmed.hasPrefix(Self.localCommandStderrTag) {
                return .system
            }
            // User lines whose content is wholly wrapped in a system-meta
            // noise tag (with no `isMeta=true` flag from Claude itself) are
            // dropped. Lines that DO carry `isMeta=true` reach this method
            // routed via tool_result blocks (see early return above), or
            // are intercepted higher up by `ClaudeRenderPolicy` as
            // `MetaChunk` content.
            for tag in Self.isMetaNullNoiseTags {
                let close = "</" + tag.dropFirst()
                if trimmed.hasPrefix(tag) && trimmed.hasSuffix(close) {
                    return .hardNoise
                }
            }
            if trimmed.hasPrefix("[Request interrupted by user") {
                return .ai
            }
            return .user

        case .blocks(let blocks):
            if blocks.count == 1,
               let only = blocks.first,
               only.type == "text",
               only.text?.hasPrefix("[Request interrupted by user") == true {
                return .ai
            }
            if blocks.contains(where: {
                $0.type == "text"
                    && ($0.text?.hasPrefix(Self.localCommandStdoutTag) == true)
            }) {
                return .system
            }
            if blocks.contains(where: { $0.type == "tool_result" }) {
                return .ai
            }
            let hasUserContent = blocks.contains {
                $0.type == "text" || $0.type == "image"
            }
            return hasUserContent ? .user : .hardNoise
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
        // Newer flow: system subtype lines carry text in the top-level
        // `content` field. Older user-line flow carries it in
        // `message.content`. Try both.
        if line.type == "system", let body = line.content, !body.isEmpty {
            return SystemChunk(
                id: line.stableId,
                output: body.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: line.timestamp ?? .distantPast
            )
        }
        guard let content = line.message?.content else { return nil }
        let raw: String
        switch content {
        case .text(let str): raw = str
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
        // Newer compact_boundary system flow: body in top-level `content`.
        if line.type == "system", let body = line.content, !body.isEmpty {
            return CompactChunk(
                id: line.stableId,
                summary: body.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: line.timestamp ?? .distantPast
            )
        }
        let summary = line.summary
            ?? extractTextContent(from: line.message?.content)
            ?? ""
        return CompactChunk(
            id: line.stableId,
            summary: summary,
            startTime: line.timestamp ?? .distantPast
        )
    }

    // MARK: - AI chunk merging (mutates BuildContext)

    private func mergeIntoPendingAIChunk(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        if ctx.pendingAIChunk == nil {
            ctx.pendingAIChunk = PendingAIChunk(
                id: line.stableId,
                startTime: line.timestamp ?? .distantPast
            )
        }
        if let ts = line.timestamp {
            ctx.pendingAIChunk?.lastTimestamp = ts
        }
        if let uuid = line.uuid {
            ctx.pendingAIChunk?.lastMessageUuid = uuid
        }

        guard let content = line.message?.content else { return }
        if let model = line.message?.model, ctx.pendingAIChunk?.model == nil {
            ctx.pendingAIChunk?.model = model
        }
        if let usage = line.message?.usage {
            ctx.pendingAIChunk?.usage.inputTokens += usage.inputTokens ?? 0
            ctx.pendingAIChunk?.usage.outputTokens += usage.outputTokens ?? 0
            ctx.pendingAIChunk?.usage.cacheReadTokens += usage.cacheReadInputTokens ?? 0
            ctx.pendingAIChunk?.usage.cacheCreationTokens += usage.cacheCreationInputTokens ?? 0
        }

        switch content {
        case .text(let str):
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendAssistantText(trimmed, ctx: &ctx)
            }
        case .blocks(let blocks):
            for block in blocks {
                switch block.type {
                case "text":
                    if let t = block.text { appendAssistantText(t, ctx: &ctx) }
                case "thinking":
                    if let t = block.thinking { appendThinkingText(t, ctx: &ctx) }
                case "tool_use":
                    appendToolUse(block, timestamp: line.timestamp, ctx: &ctx)
                case "tool_result":
                    attachToolResult(block, timestamp: line.timestamp, ctx: &ctx)
                case "image":
                    appendAssistantText("[image]", ctx: &ctx)
                default:
                    break
                }
            }
        }
    }

    private func appendAssistantText(_ text: String, ctx: inout BuildContext) {
        guard ctx.pendingAIChunk != nil else { return }
        if !ctx.pendingAIChunk!.assistantText.isEmpty {
            ctx.pendingAIChunk!.assistantText.append("\n")
        }
        ctx.pendingAIChunk!.assistantText.append(text)
    }

    private func appendThinkingText(_ text: String, ctx: inout BuildContext) {
        guard ctx.pendingAIChunk != nil else { return }
        if !ctx.pendingAIChunk!.thinkingText.isEmpty {
            ctx.pendingAIChunk!.thinkingText.append("\n")
        }
        ctx.pendingAIChunk!.thinkingText.append(text)
    }

    private func appendToolUse(
        _ block: ClaudeContentBlock,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let id = block.id, let name = block.name else { return }
        let teamMemberName = Self.extractTeamMemberName(name: name, input: block.input)
        let teamName = Self.extractTeamName(name: name, input: block.input)
        let call = AgentToolCall(
            id: id,
            name: name,
            summary: Self.summarizeToolInput(name: name, input: block.input),
            inputDetail: Self.formatToolInput(block.input),
            result: nil,
            isError: false,
            subagentType: Self.extractSubagentType(name: name, input: block.input),
            teamMemberName: teamMemberName,
            teamName: teamName,
            durationMs: nil,
            sidechainTranscript: nil
        )
        if ctx.pendingAIChunk?.toolCalls[id] == nil {
            ctx.pendingAIChunk?.toolCallOrder.append(id)
        }
        ctx.pendingAIChunk?.toolCalls[id] = call
        if let timestamp {
            ctx.pendingAIChunk?.toolStartedAt[id] = timestamp
        }
    }

    private func attachToolResult(
        _ block: ClaudeContentBlock,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let id = block.toolUseId else { return }
        let body = Self.flattenToolResult(block.toolResultContent)
        let durationMs: Int? = {
            guard let timestamp,
                  let started = ctx.pendingAIChunk?.toolStartedAt[id] else { return nil }
            let delta = timestamp.timeIntervalSince(started)
            return delta >= 0 ? Int(delta * 1000) : nil
        }()
        if let existing = ctx.pendingAIChunk?.toolCalls[id] {
            ctx.pendingAIChunk?.toolCalls[id] = AgentToolCall(
                id: existing.id,
                name: existing.name,
                summary: existing.summary,
                inputDetail: existing.inputDetail,
                result: body,
                isError: block.isError ?? false,
                subagentType: existing.subagentType,
                teamMemberName: existing.teamMemberName,
                teamName: existing.teamName,
                durationMs: durationMs,
                sidechainTranscript: existing.sidechainTranscript
            )
        } else {
            // Tool result without preceding tool_use → synthetic call.
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
                durationMs: durationMs,
                sidechainTranscript: nil
            )
            if ctx.pendingAIChunk?.toolCalls[id] == nil {
                ctx.pendingAIChunk?.toolCallOrder.append(id)
            }
            ctx.pendingAIChunk?.toolCalls[id] = synthetic
        }
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
                return truncated(cmd, max: ClaudeBuilderConsts.toolSummaryMaxChars)
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
                return truncated(prompt, max: ClaudeBuilderConsts.toolSummaryMaxChars)
            }
        case "WebFetch", "WebSearch":
            if case .string(let url)? = obj["url"] ?? obj["query"] {
                return url
            }
        default:
            break
        }
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

    /// Pretty-print a tool's input as a multi-line, key/value layout.
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
                rendered = truncated(s, max: ClaudeBuilderConsts.flattenedResultMaxChars)
            case .null, .bool, .int, .double:
                rendered = value.displayString
            case .array, .object:
                rendered = truncated(value.displayString,
                                     max: ClaudeBuilderConsts.toolInputValueMaxChars)
            }
            lines.append("\(key): \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

    static func extractSubagentType(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["subagent_type"] else {
            return nil
        }
        return s
    }

    static func extractTeamMemberName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["name"] else {
            return nil
        }
        return s
    }

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
