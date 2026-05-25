import Foundation

/// Immutable, value-type snapshot consumed by `ChunkRowView`. Keeps the row
/// view free of any reference to a store / observable object — required by
/// cmux's snapshot-boundary policy (CLAUDE.md "Snapshot boundary for list
/// subtrees").
///
/// Phase 4++ rendering revamp:
/// - The inspector no longer renders the assistant's final text body — that's
///   already visible verbatim in the paired terminal. The inspector surfaces
///   *hidden* information instead (model, tokens incl. cache breakdown,
///   thinking, tool internals, per-turn duration).
/// - User prompts are kept as compact one-line markers with full text behind
///   an expand chevron.
/// - All expandable content (user full text, thinking, tool result) is capped
///   inline at `Caps.maxLines` / `Caps.maxBytes`. Overflow surfaces an
///   `↗ Open detail` link that opens the chunk in a sibling detail tab.
struct ChunkRowSnapshot: Equatable, Identifiable {
    let id: String
    let kind: Kind
    let timestamp: Date

    // User-only
    let userPrimary: String
    let userFull: ExpandableContent
    let userCharCount: Int

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
    let thinking: ExpandableContent?
    let toolCalls: [ToolCallSnapshot]

    // System-only
    let systemBody: ExpandableContent

    // Compact-only
    let compactSummary: String

    enum Kind: Equatable {
        case user
        case ai
        case system
        case compact
    }

    /// One inline-renderable expandable text body. Stores only the truncated
    /// preview; the full body lives on the source `AgentChunk` and is fetched
    /// by the detail-panel route when the row triggers `↗ Open detail`.
    struct ExpandableContent: Equatable {
        /// Body text truncated to `Caps.maxLines` / `Caps.maxBytes`.
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
        /// Display chip shown next to the tool name. Prefers a team member
        /// `name` when present (e.g. "Alice"), else the `subagent_type`
        /// uppercased (e.g. "TASK"), matching claude-devtools'
        /// `SubagentItem.tsx:304-326` rendering.
        let subagentChip: String?
        /// Tool-call duration in milliseconds when the JSONL provides both a
        /// `tool_use` and matching `tool_result` timestamp. Nil otherwise.
        let durationMs: Int?

        /// Mirrors claude-devtools' three-state status dot vocabulary
        /// (`BaseItem.tsx:53-60`): pending = yellow, ok = green, error = red.
        enum Status: Equatable {
            case pending
            case ok
            case error
        }
    }

    /// Inline expansion limits. Anything past these caps is replaced with an
    /// `↗ Open detail` link.
    ///
    /// **maxLines (200):** ~10 visible scrollback heights at typical inspector
    /// widths. Beyond this, the row dwarfs neighbouring chunks; opening
    /// detail in a sibling tab gives more room.
    /// **maxBytes (8 KiB):** safety cap for pathologically dense single
    /// lines (e.g. one-line minified JSON). Empirically rare in claude
    /// transcripts but cheap insurance.
    enum Caps {
        static let maxLines: Int = 200
        static let maxBytes: Int = 8 * 1024
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
            return makeCompact(c)
        case .meta(let c):
            // Phase A placeholder. MetaChunk rendering lands in Phase B.
            // Builder does not emit `.meta` chunks until A.7 wires routing,
            // so this branch is unreachable during Phase A; the temporary
            // CompactChunk-shaped snapshot keeps the switch exhaustive
            // without inventing a render path that Phase B would discard.
            return makeCompact(CompactChunk(
                id: c.id,
                summary: "[meta-chunk placeholder]",
                startTime: c.startTime
            ))
        }
    }

    /// Display label for the agent kind. Mirrors claude-devtools'
    /// `AIChatGroup.tsx:413` literal "Claude" string. We expand this enum so
    /// the inspector can render the right brand label when codex is paired.
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
        return ChunkRowSnapshot(
            id: c.id,
            kind: .user,
            timestamp: c.startTime,
            userPrimary: primary,
            userFull: makeExpandable(c.text, displayMode: displayMode),
            userCharCount: c.text.count,
            aiHeaderLabel: "",
            modelLabel: nil,
            modelFriendly: nil,
            tokens: .empty,
            durationSeconds: nil,
            thinking: nil,
            toolCalls: [],
            systemBody: .empty,
            compactSummary: ""
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

        let thinkingContent: ExpandableContent? = {
            let trimmed = c.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return makeExpandable(c.thinkingText, displayMode: displayMode)
        }()

        return ChunkRowSnapshot(
            id: c.id,
            kind: .ai,
            timestamp: c.startTime,
            userPrimary: "",
            userFull: .empty,
            userCharCount: 0,
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
                    input: makeExpandable(tc.inputDetail, displayMode: displayMode),
                    result: makeExpandable(tc.result ?? "", displayMode: displayMode),
                    status: status,
                    subagentChip: makeSubagentChip(tc),
                    durationMs: tc.durationMs
                )
            },
            systemBody: .empty,
            compactSummary: ""
        )
    }

    private static func makeSystem(_ c: SystemChunk, displayMode: DisplayMode) -> ChunkRowSnapshot {
        ChunkRowSnapshot(
            id: c.id,
            kind: .system,
            timestamp: c.startTime,
            userPrimary: "",
            userFull: .empty,
            userCharCount: 0,
            aiHeaderLabel: "",
            modelLabel: nil,
            modelFriendly: nil,
            tokens: .empty,
            durationSeconds: nil,
            thinking: nil,
            toolCalls: [],
            systemBody: makeExpandable(c.output, displayMode: displayMode),
            compactSummary: ""
        )
    }

    private static func makeCompact(_ c: CompactChunk) -> ChunkRowSnapshot {
        let trimmed = c.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed.isEmpty ? "[compacted]" : oneLine(trimmed, maxChars: 200)
        return ChunkRowSnapshot(
            id: c.id,
            kind: .compact,
            timestamp: c.startTime,
            userPrimary: "",
            userFull: .empty,
            userCharCount: 0,
            aiHeaderLabel: "",
            modelLabel: nil,
            modelFriendly: nil,
            tokens: .empty,
            durationSeconds: nil,
            thinking: nil,
            toolCalls: [],
            systemBody: .empty,
            compactSummary: summary
        )
    }

    /// Build the chip label shown next to a tool name. Prefers a team-member
    /// `name` when the Task input set one (claude-devtools `SubagentItem.tsx`
    /// renders this verbatim), else uppercases the `subagent_type` to match
    /// the typed-subagent badge style (e.g. `general-purpose` → `GENERAL-PURPOSE`).
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

    private static func makeExpandable(_ text: String, displayMode: DisplayMode) -> ExpandableContent {
        if text.isEmpty {
            return .empty
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let totalLines = lines.count
        switch displayMode {
        case .fullDetail:
            return ExpandableContent(inlineBody: text, totalLines: totalLines, overflow: false)
        case .compact:
            let byteCount = text.utf8.count
            let lineOverflow = totalLines > Caps.maxLines
            let byteOverflow = byteCount > Caps.maxBytes
            guard lineOverflow || byteOverflow else {
                return ExpandableContent(inlineBody: text, totalLines: totalLines, overflow: false)
            }
            // Cap by lines first, then enforce byte cap on the truncated body.
            var truncated = lineOverflow
                ? lines.prefix(Caps.maxLines).joined(separator: "\n")
                : text
            if truncated.utf8.count > Caps.maxBytes {
                // Step back from the byte cap to a `Character`-grain
                // boundary so we never split a multi-byte UTF-8 sequence
                // (which would produce a string with invalid trailing code
                // units when decoded back). Walk character-by-character
                // until adding the next one would exceed the cap.
                var truncatedToBoundary = ""
                truncatedToBoundary.reserveCapacity(Caps.maxBytes)
                for character in truncated {
                    if truncatedToBoundary.utf8.count + character.utf8.count > Caps.maxBytes {
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
}

extension ChunkRowSnapshot.TokenBreakdown {
    /// Total across all four buckets — used for the compact (collapsed)
    /// header label so the AI row reads as a single number when not
    /// expanded.
    var total: Int { input + output + cacheRead + cacheWrite }

    /// Compact (collapsed) representation: e.g. `19.3k tokens`.
    var compactSummaryLabel: String {
        guard total > 0 else { return "" }
        return "\(formatTokens(total)) tokens"
    }

    /// Detailed (expanded) representation, one segment per non-zero bucket.
    /// Format: `<value><label>` (no internal whitespace), with shorthands for
    /// cache (cr / cw). Caller renders dots between segments.
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
