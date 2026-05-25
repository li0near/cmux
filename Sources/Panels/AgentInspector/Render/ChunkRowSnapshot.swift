import Foundation

/// Immutable, value-type snapshot consumed by `ChunkRowView`. Keeps the row
/// view free of any reference to a store / observable object — required by
/// cmux's snapshot-boundary policy (CLAUDE.md "Snapshot boundary for list
/// subtrees").
///
/// Render policy:
/// - The inspector surfaces *hidden* information (model, tokens incl. cache
///   breakdown, thinking, tool internals, per-turn duration) in addition to
///   newer Phase B Meta surfaces (branch links, recap, PR links, slash
///   commands, skill titles, system reminders, etc.).
/// - User prompts stay compact one-line markers with full text behind an
///   expand chevron.
/// - Per-section caps live in `InspectorCaps` (single source of truth);
///   `makeExpandable(_:caps:displayMode:)` applies the appropriate cap to
///   each section. Overflow surfaces an `↗ Open detail` link.
struct ChunkRowSnapshot: Equatable, Identifiable {
    let id: String
    let kind: Kind
    let timestamp: Date

    // User-only
    let userPrimary: String
    let userFull: ExpandableContent
    let userCharCount: Int
    /// Word count of the user prompt's full text. Surfaced in the
    /// metadata pill ("N words") in place of `userCharCount` ("N
    /// chars") since words read more naturally for prose.
    let userWordCount: Int

    // AI-only
    /// Friendly label for the agent kind ("Claude", "Codex"). Defaults to
    /// "AI" when the agent kind is unknown — usable as a header prefix.
    let aiHeaderLabel: String
    /// Raw model id as reported by the agent (e.g. "claude-sonnet-4-5-20250929").
    let modelLabel: String?
    /// Display-friendly model name parsed from `modelLabel`
    /// (e.g. "Sonnet 4.5"). Nil when no model is known.
    let modelFriendly: String?
    let tokens: TokenBreakdown
    let durationSeconds: TimeInterval?
    /// Per-turn aggregate duration sourced from `system.subtype: turn_duration`,
    /// pre-formatted ("4m 33s"). Preferred over `durationSeconds` when
    /// available; the renderer falls back to local computation otherwise.
    let perTurnDurationLabel: String?
    /// Total messages in the turn (from `turn_duration.messageCount`).
    let perTurnMessageCount: Int?
    let thinking: ExpandableContent?
    let toolCalls: [ToolCallSnapshot]
    /// Phase B: assistant final text body. Always rendered as a
    /// title-only link to a detail tab — never inline (per the
    /// `InspectorCaps.assistantText.alwaysLink` binding). Nil when the
    /// AI chunk has no assistant text yet (rare; mid-stream tool-only).
    let assistantTextOverflow: ExpandableContent?
    /// Word count of the assistant response. Surfaced in the `↗ assistant
    /// response · N words` link label (per design feedback — words read
    /// more naturally than lines for prose).
    let assistantTextWordCount: Int

    // System-only
    let systemBody: ExpandableContent

    // Compact-only
    let compactSummary: String

    // Meta-only — populated when `kind == .meta(...)`.
    let meta: MetaSnapshot?

    enum Kind: Equatable {
        case user
        case ai
        case system
        case compact
        case meta(MetaKind)
    }

    /// Discriminator for `MetaSnapshot` subkinds. Drives icon + color
    /// selection in the renderer.
    enum MetaKind: Equatable {
        case branchLink
        case recap
        case prLink
        case skillTitle
        case slashCmdInput
        case slashCmdOutput(isStderr: Bool)
        case localCommandCaveat
        case systemReminder
        case contextUsage
        case continueResume
    }

    /// Lightweight snapshot for every `MetaChunk` variant. Single struct
    /// (rather than ten payload-bearing enum cases) keeps the renderer's
    /// `TitleRowWithOptionalDetail` shared layout simple.
    struct MetaSnapshot: Equatable {
        let title: String
        let subtitle: String?
        /// Inline body — empty + `.alwaysLink` caps means render only the
        /// title with a detail-route link.
        let body: ExpandableContent
        /// Detail-route invoked when the user clicks the row's title or
        /// the trailing `↗` link. Some metas (PrLink, ContinueResume,
        /// SlashCmdInput) have no detail route — the row is purely
        /// informational.
        let detailRequest: InspectorDetailRequest?
        /// External URL to open instead of a detail tab — used by `prLink`.
        let externalUrl: String?
    }

    /// One inline-renderable expandable text body. Stores only the truncated
    /// preview; the full body lives on the source `AgentChunk` and is fetched
    /// by the detail-panel route when the row triggers `↗ Open detail`.
    struct ExpandableContent: Equatable {
        /// Body text truncated to the section's caps from `InspectorCaps`.
        let inlineBody: String
        /// Total line count of the original (pre-truncation) text.
        let totalLines: Int
        /// True when the original exceeded the inline cap.
        let overflow: Bool

        static let empty = ExpandableContent(inlineBody: "", totalLines: 0, overflow: false)
        var isEmpty: Bool { inlineBody.isEmpty && !overflow }
    }

    /// Per-message token breakdown surfaced separately from in/out so the
    /// metadata strip can render cache_read and cache_creation distinctly.
    struct TokenBreakdown: Equatable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int

        static let empty = TokenBreakdown(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        var isEmpty: Bool {
            input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0
        }
    }

    struct ToolCallSnapshot: Equatable, Identifiable {
        let id: String
        let name: String
        /// One-line summary derived from the tool's input arguments.
        let summary: String
        let input: ExpandableContent
        /// Result body. `inlineBody.isEmpty && !overflow` indicates pending.
        let result: ExpandableContent
        let status: Status
        var isError: Bool { status == .error }
        /// Display chip shown next to the tool name.
        let subagentChip: String?
        /// Tool-call duration in milliseconds when both timestamps were
        /// available. Nil otherwise.
        let durationMs: Int?
        /// Phase B: number of chunks in the attached sub-agent transcript
        /// (Task / Agent tools). nil when the tool didn't spawn a
        /// sub-agent. Renderer uses this to surface the
        /// `↳ Sub-agent transcript` link inside the tool row.
        let sidechainChunkCount: Int?

        /// Mirrors claude-devtools' three-state status dot vocabulary
        /// (`BaseItem.tsx:53-60`): pending = yellow, ok = green, error = red.
        enum Status: Equatable {
            case pending
            case ok
            case error
        }
    }

    /// Display mode for the snapshot. Used by the detail-panel path to render
    /// the same chunk without inline truncation. The compact-mode snapshot is
    /// what the main inspector list uses.
    enum DisplayMode {
        case compact
        case fullDetail
    }
}

extension ChunkRowSnapshot {
    /// Build a row snapshot from one `AgentChunk`. Caps and summarisation
    /// happen here, not in the row view, so the renderer only reads fields.
    static func from(
        _ chunk: AgentChunk,
        agentKind: AgentKindLabel = .unknown,
        displayMode: DisplayMode = .compact
    ) -> ChunkRowSnapshot {
        switch chunk {
        case .user(let c):
            return makeUser(c, displayMode: displayMode)
        case .ai(let c):
            return makeAI(c, agentKind: agentKind, displayMode: displayMode)
        case .system(let c):
            return makeSystem(c, displayMode: displayMode)
        case .compact(let c):
            return makeCompact(c, displayMode: displayMode)
        case .meta(let c):
            return makeMeta(c, displayMode: displayMode)
        }
    }

    /// Display label for the agent kind.
    enum AgentKindLabel: Equatable {
        case claude
        case codex
        case unknown

        var headerLabel: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .unknown: return "AI"
            }
        }
    }

    private static func makeUser(_ c: UserChunk, displayMode: DisplayMode) -> ChunkRowSnapshot {
        let primary = oneLine(c.text, maxChars: 80)
        let words = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
        return base(
            id: c.id,
            kind: .user,
            timestamp: c.startTime,
            userPrimary: primary,
            userFull: makeExpandable(c.text, caps: InspectorCaps.userPrompt, displayMode: displayMode),
            userCharCount: c.text.count,
            userWordCount: words
        )
    }

    private static func makeAI(
        _ c: AIChunk,
        agentKind: AgentKindLabel = .unknown,
        displayMode: DisplayMode
    ) -> ChunkRowSnapshot {
        let duration: TimeInterval? = {
            guard let end = c.endTime else { return nil }
            let delta = end.timeIntervalSince(c.startTime)
            return delta >= 0 ? delta : nil
        }()
        let perTurnLabel: String? = c.perTurnDurationMs.map { ms in
            formatDurationLabel(ms: ms)
        }

        let thinkingContent: ExpandableContent? = {
            let trimmed = c.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return makeExpandable(c.thinkingText, caps: InspectorCaps.thinking, displayMode: displayMode)
        }()

        let assistantOverflow: ExpandableContent? = {
            let trimmed = c.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // assistantText is `alwaysLink` — overflow flag is always
            // true when there's content. The renderer surfaces a title
            // row + detail link; no inline body.
            return makeExpandable(c.assistantText, caps: InspectorCaps.assistantText, displayMode: displayMode)
        }()
        let assistantWords: Int = {
            let trimmed = c.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            return trimmed.split { $0.isWhitespace || $0.isNewline }.count
        }()

        return ChunkRowSnapshot(
            id: c.id,
            kind: .ai,
            timestamp: c.startTime,
            userPrimary: "",
            userFull: .empty,
            userCharCount: 0,
            userWordCount: 0,
            aiHeaderLabel: agentKind.headerLabel,
            modelLabel: c.model,
            modelFriendly: c.model.flatMap(ClaudeModelNameMap.friendlyName(for:)),
            tokens: TokenBreakdown(
                input: c.usage.inputTokens,
                output: c.usage.outputTokens,
                cacheRead: c.usage.cacheReadTokens,
                cacheWrite: c.usage.cacheCreationTokens
            ),
            durationSeconds: duration,
            perTurnDurationLabel: perTurnLabel,
            perTurnMessageCount: c.messageCount,
            thinking: thinkingContent,
            toolCalls: c.toolCalls.map { tc in
                let status: ToolCallSnapshot.Status = {
                    if tc.isError { return .error }
                    if tc.result == nil { return .pending }
                    return .ok
                }()
                return ToolCallSnapshot(
                    id: tc.id,
                    name: tc.name,
                    summary: tc.summary,
                    input: makeExpandable(tc.inputDetail, caps: InspectorCaps.toolInput, displayMode: displayMode),
                    result: makeExpandable(tc.result ?? "", caps: InspectorCaps.toolResult, displayMode: displayMode),
                    status: status,
                    subagentChip: makeSubagentChip(tc),
                    durationMs: tc.durationMs,
                    sidechainChunkCount: tc.sidechainTranscript?.count
                )
            },
            assistantTextOverflow: assistantOverflow,
            assistantTextWordCount: assistantWords,
            systemBody: .empty,
            compactSummary: "",
            meta: nil
        )
    }

    private static func makeSystem(_ c: SystemChunk, displayMode: DisplayMode) -> ChunkRowSnapshot {
        base(
            id: c.id,
            kind: .system,
            timestamp: c.startTime,
            systemBody: makeExpandable(c.output, caps: InspectorCaps.systemBody, displayMode: displayMode)
        )
    }

    private static func makeCompact(_ c: CompactChunk, displayMode: DisplayMode) -> ChunkRowSnapshot {
        let trimmed = c.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed.isEmpty ? "[compacted]" : oneLine(trimmed, maxChars: 200)
        return base(
            id: c.id,
            kind: .compact,
            timestamp: c.startTime,
            compactSummary: summary
        )
    }

    private static func makeMeta(_ c: MetaChunk, displayMode: DisplayMode) -> ChunkRowSnapshot {
        switch c {
        case .branchLink(let b):
            let preview = b.firstPromptPreview ?? "(no prompt)"
            return base(
                id: b.id,
                kind: .meta(.branchLink),
                timestamp: b.startTime,
                meta: MetaSnapshot(
                    title: "Rewind \(b.rewindIndex) of \(b.totalRewinds)",
                    subtitle: "\(b.chunkCount) chunks · \(preview)",
                    body: .empty,
                    detailRequest: .abandonedBranch(branchRootUuid: b.id),
                    externalUrl: nil
                )
            )
        case .recap(let r):
            let body = makeExpandable(r.body, caps: InspectorCaps.recapBody, displayMode: displayMode)
            return base(
                id: r.id,
                kind: .meta(.recap),
                timestamp: r.startTime,
                meta: MetaSnapshot(
                    title: "Recap",
                    subtitle: nil,
                    body: body,
                    detailRequest: .recapBody(chunkId: r.id),
                    externalUrl: nil
                )
            )
        case .prLink(let p):
            return base(
                id: p.id,
                kind: .meta(.prLink),
                timestamp: p.startTime,
                meta: MetaSnapshot(
                    title: "PR #\(p.prNumber)",
                    subtitle: p.prRepository,
                    body: .empty,
                    detailRequest: nil,
                    externalUrl: p.prUrl
                )
            )
        case .skillTitle(let s):
            return base(
                id: s.id,
                kind: .meta(.skillTitle),
                timestamp: s.startTime,
                meta: MetaSnapshot(
                    title: "Skill: \(s.skillName)",
                    subtitle: s.basePath,
                    body: .empty,
                    detailRequest: .skillBody(chunkId: s.id),
                    externalUrl: nil
                )
            )
        case .slashCmdInput(let i):
            let title = i.args.map { "/\(i.commandName) \($0)" } ?? "/\(i.commandName)"
            return base(
                id: i.id,
                kind: .meta(.slashCmdInput),
                timestamp: i.startTime,
                meta: MetaSnapshot(
                    title: title,
                    subtitle: nil,
                    body: .empty,
                    detailRequest: nil,
                    externalUrl: nil
                )
            )
        case .slashCmdOutput(let o):
            let body = makeExpandable(o.body, caps: InspectorCaps.slashCmdOutput, displayMode: displayMode)
            return base(
                id: o.id,
                kind: .meta(.slashCmdOutput(isStderr: o.isStderr)),
                timestamp: o.startTime,
                meta: MetaSnapshot(
                    title: o.isStderr ? "Slash command stderr" : "Slash command output",
                    subtitle: nil,
                    body: body,
                    detailRequest: nil,
                    externalUrl: nil
                )
            )
        case .localCommandCaveat(let l):
            let body = makeExpandable(l.body, caps: InspectorCaps.localCommandCaveat, displayMode: displayMode)
            return base(
                id: l.id,
                kind: .meta(.localCommandCaveat),
                timestamp: l.startTime,
                meta: MetaSnapshot(
                    title: "Caveat",
                    subtitle: nil,
                    body: body,
                    detailRequest: body.overflow ? .localCommandCaveatBody(chunkId: l.id) : nil,
                    externalUrl: nil
                )
            )
        case .systemReminder(let r):
            let body = makeExpandable(r.body, caps: InspectorCaps.systemReminder, displayMode: displayMode)
            return base(
                id: r.id,
                kind: .meta(.systemReminder),
                timestamp: r.startTime,
                meta: MetaSnapshot(
                    title: "System reminder",
                    subtitle: nil,
                    body: body,
                    detailRequest: body.overflow ? .systemReminderBody(chunkId: r.id) : nil,
                    externalUrl: nil
                )
            )
        case .contextUsage(let cu):
            let body = makeExpandable(cu.body, caps: InspectorCaps.contextUsage, displayMode: displayMode)
            return base(
                id: cu.id,
                kind: .meta(.contextUsage),
                timestamp: cu.startTime,
                meta: MetaSnapshot(
                    title: "Context usage",
                    subtitle: nil,
                    body: body,
                    detailRequest: nil,
                    externalUrl: nil
                )
            )
        case .continueResume(let m):
            return base(
                id: m.id,
                kind: .meta(.continueResume),
                timestamp: m.startTime,
                meta: MetaSnapshot(
                    title: "[resumed]",
                    subtitle: nil,
                    body: .empty,
                    detailRequest: nil,
                    externalUrl: nil
                )
            )
        }
    }

    /// Build the chip label shown next to a tool name.
    private static func makeSubagentChip(_ tc: AgentToolCall) -> String? {
        if let name = tc.teamMemberName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if let subagent = tc.subagentType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subagent.isEmpty {
            return subagent.uppercased()
        }
        return nil
    }

    // MARK: - Helpers

    /// All-defaults factory; concrete makers override only the fields that
    /// matter for their kind. Keeps each maker short and intent-focused.
    private static func base(
        id: String,
        kind: Kind,
        timestamp: Date,
        userPrimary: String = "",
        userFull: ExpandableContent = .empty,
        userCharCount: Int = 0,
        userWordCount: Int = 0,
        systemBody: ExpandableContent = .empty,
        compactSummary: String = "",
        meta: MetaSnapshot? = nil
    ) -> ChunkRowSnapshot {
        ChunkRowSnapshot(
            id: id,
            kind: kind,
            timestamp: timestamp,
            userPrimary: userPrimary,
            userFull: userFull,
            userCharCount: userCharCount,
            userWordCount: userWordCount,
            aiHeaderLabel: "",
            modelLabel: nil,
            modelFriendly: nil,
            tokens: .empty,
            durationSeconds: nil,
            perTurnDurationLabel: nil,
            perTurnMessageCount: nil,
            thinking: nil,
            toolCalls: [],
            assistantTextOverflow: nil,
            assistantTextWordCount: 0,
            systemBody: systemBody,
            compactSummary: compactSummary,
            meta: meta
        )
    }

    /// Truncate `text` to the section's caps. `alwaysLink` short-circuits
    /// to an empty inline body with `overflow=true` (renderer surfaces a
    /// title-only row with a detail link).
    static func makeExpandable(
        _ text: String,
        caps: InspectorSectionCaps,
        displayMode: DisplayMode
    ) -> ExpandableContent {
        if text.isEmpty { return .empty }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let totalLines = lines.count

        if caps.alwaysLink && displayMode == .compact {
            return ExpandableContent(inlineBody: "", totalLines: totalLines, overflow: true)
        }

        switch displayMode {
        case .fullDetail:
            return ExpandableContent(inlineBody: text, totalLines: totalLines, overflow: false)
        case .compact:
            let byteCount = text.utf8.count
            let lineOverflow = totalLines > caps.maxLines
            let byteOverflow = byteCount > caps.maxBytes
            guard lineOverflow || byteOverflow else {
                return ExpandableContent(inlineBody: text, totalLines: totalLines, overflow: false)
            }
            var truncated = lineOverflow
                ? lines.prefix(caps.maxLines).joined(separator: "\n")
                : text
            if truncated.utf8.count > caps.maxBytes {
                var truncatedToBoundary = ""
                truncatedToBoundary.reserveCapacity(caps.maxBytes)
                for character in truncated {
                    if truncatedToBoundary.utf8.count + character.utf8.count > caps.maxBytes {
                        break
                    }
                    truncatedToBoundary.append(character)
                }
                truncated = truncatedToBoundary
            }
            return ExpandableContent(
                inlineBody: truncated,
                totalLines: totalLines,
                overflow: true
            )
        }
    }

    private static func oneLine(_ text: String, maxChars: Int) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= maxChars { return trimmed }
        let prefix = trimmed.prefix(maxChars - 1)
        return String(prefix) + "…"
    }

    private static func formatDurationLabel(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }
}

extension ChunkRowSnapshot.TokenBreakdown {
    var total: Int { input + output + cacheRead + cacheWrite }

    var compactSummaryLabel: String {
        guard total > 0 else { return "" }
        return "\(formatTokens(total)) tokens"
    }

    var labels: [String] {
        guard !isEmpty else { return [] }
        var parts: [String] = []
        if input > 0 { parts.append("\(formatTokens(input))in") }
        if output > 0 { parts.append("\(formatTokens(output))out") }
        if cacheRead > 0 { parts.append("\(formatTokens(cacheRead))cr") }
        if cacheWrite > 0 { parts.append("\(formatTokens(cacheWrite))cw") }
        return parts
    }

    private func formatTokens(_ count: Int) -> String {
        if count < 1000 { return String(count) }
        if count < 1_000_000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }
}
