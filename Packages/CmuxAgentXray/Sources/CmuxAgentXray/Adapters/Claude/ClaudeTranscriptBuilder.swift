import Foundation

/// Builds an `[Entry]` transcript from a stream of raw Claude JSONL
/// lines.
///
/// Two-pass design:
///   1. **Pre-pass resolvers** — pure value functions over `rawLines`:
///      `ClaudeBranchResolver` (active-branch + abandoned-branch
///      grouping), `ClaudeTurnDurationResolver` (per-turn timing
///      stamps), `ClaudeQueuedPromptResolver` (queued slash UUIDs +
///      pending-prompt descriptors), `ClaudeSkillCommandResolver`
///      (skill-shaped `<command-message>` UUIDs).
///   2. **Dispatch loop** — for every buffered line,
///      `ClaudeLineDispatcher.route(...)` decides skip / sidechain /
///      abandoned-branch / render. Sidechain lines are pooled by
///      `parentToolUseID`; abandoned branches surface as
///      `SynthesizedEntry.branchLink` entries at their divergence
///      points.
///
/// Each `transcript()` call rebuilds from scratch — cheap for typical
/// sessions and ensures rewinds landing mid-session collapse the
/// transcript immediately.
struct ClaudeTranscriptBuilder {

    // MARK: - Tag constants

    static let localCommandStdoutTag = "<local-command-stdout>"
    static let localCommandStderrTag = "<local-command-stderr>"
    private static let localCommandCaveatTag = "<local-command-caveat>"
    private static let systemReminderTag = "<system-reminder>"

    /// User lines whose content is entirely wrapped in one of these
    /// tags are dropped when `isMeta` is null/false. (`isMeta=true`
    /// lines with the same tags route to a `SystemEntry` with the
    /// matching subType.)
    private static let isMetaNullNoiseTags: [String] = [
        localCommandCaveatTag,
        systemReminderTag,
    ]

    private static let emptyStdout = "<local-command-stdout></local-command-stdout>"
    private static let emptyStderr = "<local-command-stderr></local-command-stderr>"

    // MARK: - State

    private var rawLines: [ClaudeJSONLLine] = []
    private let logger: any AgentXrayLogger

    init(logger: any AgentXrayLogger = NoOpAgentXrayLogger()) {
        self.logger = logger
    }

    // MARK: - API

    /// Append one decoded line to the buffer. File order is conversation
    /// order. Re-derivation happens on the next `transcript()` call.
    mutating func ingest(_ line: ClaudeJSONLLine) {
        rawLines.append(line)
    }

    /// Clears the buffer. Used when the underlying file rotates.
    mutating func reset() {
        rawLines.removeAll()
    }

    /// Rebuild the full transcript from the buffered lines. Pure value
    /// transformation; safe to call on any actor.
    func transcript() -> [Entry] {
        let branchResolution = ClaudeBranchResolver.resolve(lines: rawLines)
        let turnDurations = ClaudeTurnDurationResolver.resolve(lines: rawLines)
        let queued = ClaudeQueuedPromptResolver.resolve(lines: rawLines)
        let skill = ClaudeSkillCommandResolver.resolve(lines: rawLines)

        var ctx = BuildContext(resolution: branchResolution)
        ctx.turnDurations = turnDurations.stamps
        ctx.queuedSlashCommandUuids = queued.wasQueuedSlashUuids
        ctx.skillCommandUuids = skill.skillCommandUuids

        // Pre-pass: build entry transcripts for each abandoned branch.
        var branchEntriesByRoot: [String: [Entry]] = [:]
        for branch in ctx.resolution.abandonedBranches {
            let lines = rawLines.filter { line in
                guard let uuid = line.uuid else { return false }
                return branch.memberUUIDs.contains(uuid)
            }
            branchEntriesByRoot[branch.branchRootUuid] = buildAbandonedBranchEntries(from: lines)
        }
        ctx.abandonedBranchEntriesByRoot = branchEntriesByRoot

        // Emit orphan-abandoned branch links at the very start of the
        // output stream — they have no divergence point, so no later
        // active line will trigger their emission.
        for branch in ctx.resolution.abandonedBranches
        where branch.divergencePointUuid == nil
            && !ctx.emittedDivergencePoints.contains(branch.branchRootUuid) {
            ctx.emittedDivergencePoints.insert(branch.branchRootUuid)
            let entries = branchEntriesByRoot[branch.branchRootUuid] ?? []
            ctx.entries.append(.synthesized(buildBranchLinkEntry(
                branch: branch,
                totalRewinds: ctx.resolution.totalRewinds,
                branchEntries: entries,
                timestamp: rawLines.first?.timestamp ?? .distantPast
            )))
        }

        for line in rawLines {
            dispatch(line, ctx: &ctx)
        }
        ctx.flushPendingTurn()

        // Tail-append synthetic pending UserEntry instances for unconsumed
        // `queue-operation enqueue` descriptors. Once consumed, the
        // matching `attachment.queued_command` emits its own non-pending
        // UserEntry and the pending pseudo-entry drops out of the next
        // transcript.
        for pending in queued.pendingPrompts {
            ctx.entries.append(.user(buildPendingUserEntry(pending)))
        }

        return ctx.entries
    }

    /// Recursively build entries for an abandoned-branch transcript.
    private func buildAbandonedBranchEntries(from lines: [ClaudeJSONLLine]) -> [Entry] {
        var sub = ClaudeTranscriptBuilder()
        for line in lines { sub.ingest(line) }
        return sub.transcript()
    }

    // MARK: - Top-level dispatch

    private func dispatch(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        if line.type == "system", line.subtype == "turn_duration" {
            return
        }

        let routing = ClaudeLineDispatcher.route(
            line,
            activeBranch: ctx.resolution.activeUUIDs,
            activeBranchAvailable: ctx.resolution.leafUuid != nil,
            skillCommandUuids: ctx.skillCommandUuids,
            logger: logger
        )

        switch routing {
        case .skip:
            return
        case .skipBranchAffiliated:
            return
        case .sidechainMain:
            ctx.collectSidechainLine(line)
            return
        case .render(let kind):
            ctx.maybeEmitBranchLinks(beforeAdjacentTo: line)

            switch kind {
            case .compact:
                ctx.flushPendingTurn()
                ctx.entries.append(.compact(buildCompactEntry(from: line)))
            case .user:
                let cat = classify(line)
                switch cat {
                case .compact:
                    ctx.flushPendingTurn()
                    ctx.entries.append(.compact(buildCompactEntry(from: line)))
                case .user:
                    ctx.flushPendingTurn()
                    if let entry = buildUserEntry(from: line, ctx: ctx) {
                        ctx.entries.append(.user(entry))
                    }
                case .system:
                    ctx.flushPendingTurn()
                    if let entry = buildSystemEntry(from: line) {
                        ctx.entries.append(.system(entry))
                    }
                case .agent:
                    mergeIntoPendingTurn(line, ctx: &ctx)
                case .hardNoise:
                    return
                }
            case .system:
                ctx.flushPendingTurn()
                if let entry = buildSystemEntry(from: line) {
                    ctx.entries.append(.system(entry))
                }
            case .agent:
                mergeIntoPendingTurn(line, ctx: &ctx)
            }
        case .renderSpecial(let kind):
            ctx.maybeEmitBranchLinks(beforeAdjacentTo: line)
            ctx.flushPendingTurn()
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
            let recapBody = (line.content ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
            if recapBody.isEmpty { return }
            ctx.entries.append(.system(SystemEntry(
                id: .fromJSONL(id),
                timestamp: ts,
                header: Header(
                    icon: .recap,
                    name: String(
                        localized: "agentXray.entry.recap.title",
                        defaultValue: "Recap",
                        bundle: .module
                    ),
                    timestamp: ts
                ),
                body: .text([recapBody]),
                subType: .recap
            )))
        case .prLink:
            guard let prNumber = line.prNumber,
                  let prUrl = line.prUrl,
                  let prRepository = line.prRepository else { return }
            ctx.entries.append(.synthesized(SynthesizedEntry(
                id: .derived(parent: id, kind: "prLink"),
                timestamp: ts,
                header: Header(
                    icon: .prLink,
                    title: String(
                        localized: "agentXray.entry.prLink.title",
                        defaultValue: "PR #\(prNumber) · \(prRepository)",
                        bundle: .module
                    ),
                    timestamp: ts
                ),
                body: .empty,
                kind: .prLink(prNumber: prNumber, url: prUrl, repository: prRepository)
            )))
        case .continueResume:
            return
        case .slashCmdInput:
            if ctx.queuedSlashCommandUuids.contains(line.stableId) {
                let text = ClaudeQueuedPromptResolver.consumedSlashCommandText(line) ?? body
                ctx.entries.append(.user(makeUserEntry(
                    id: id,
                    timestamp: ts,
                    promptId: line.promptId,
                    text: text,
                    wasQueued: true,
                    isQueuedPending: false
                )))
            } else if case let .slashCommandInput(name, args)
                        = ClaudeContentDetector.classify(body) {
                let title = args.map { "/\(name) \($0)" } ?? "/\(name)"
                ctx.entries.append(.system(SystemEntry(
                    id: .fromJSONL(id),
                    timestamp: ts,
                    header: Header(
                        icon: .slashCommand,
                        title: title,
                        timestamp: ts
                    ),
                    body: .empty,
                    subType: .slashCmdInput(name: name, args: args)
                )))
            }
        case .slashCmdOutput:
            if case let .slashCommandOutput(b, isStderr) = ClaudeContentDetector.classify(body) {
                if b.isEmpty { return }
                let label = isStderr
                    ? String(
                        localized: "agentXray.entry.slashCmd.stderr",
                        defaultValue: "Slash command stderr",
                        bundle: .module
                      )
                    : String(
                        localized: "agentXray.entry.slashCmd.output",
                        defaultValue: "Slash command output",
                        bundle: .module
                      )
                ctx.entries.append(.system(SystemEntry(
                    id: .fromJSONL(id),
                    timestamp: ts,
                    header: Header(icon: .system, name: label, timestamp: ts),
                    body: Body(sections: [.text([b], style: isStderr ? .error : .normal)]),
                    subType: .slashCmdOutput(isStderr: isStderr)
                )))
            }
        case .localCommandCaveat:
            return
        case .systemReminder:
            if case let .systemReminder(b) = ClaudeContentDetector.classify(body) {
                ctx.entries.append(.system(SystemEntry(
                    id: .fromJSONL(id),
                    timestamp: ts,
                    header: Header(
                        icon: .systemReminder,
                        name: String(
                            localized: "agentXray.entry.systemReminder.title",
                            defaultValue: "System reminder",
                            bundle: .module
                        ),
                        timestamp: ts
                    ),
                    body: .text([b]),
                    subType: .systemReminder
                )))
            }
        case .skill:
            if case let .skillInvocation(name, basePath, b) = ClaudeContentDetector.classify(body) {
                ctx.entries.append(.system(SystemEntry(
                    id: .fromJSONL(id),
                    timestamp: ts,
                    header: Header(
                        icon: .skill,
                        name: String(
                            localized: "agentXray.entry.skill.title",
                            defaultValue: "Skill: \(name)",
                            bundle: .module
                        ),
                        title: basePath,
                        timestamp: ts
                    ),
                    body: .text([b]),
                    subType: .skill(name: name, basePath: basePath)
                )))
            }
        case .contextUsage:
            if case let .contextUsage(b) = ClaudeContentDetector.classify(body) {
                ctx.entries.append(.system(SystemEntry(
                    id: .fromJSONL(id),
                    timestamp: ts,
                    header: Header(
                        icon: .contextInfo,
                        name: String(
                            localized: "agentXray.entry.contextUsage.title",
                            defaultValue: "Context usage",
                            bundle: .module
                        ),
                        timestamp: ts
                    ),
                    body: .text([b]),
                    subType: .contextUsage
                )))
            }
        case .unknownMeta:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            ctx.entries.append(.system(SystemEntry(
                id: .fromJSONL(id),
                timestamp: ts,
                header: Header(
                    icon: .systemReminder,
                    name: String(
                        localized: "agentXray.entry.systemReminder.title",
                        defaultValue: "System reminder",
                        bundle: .module
                    ),
                    timestamp: ts
                ),
                body: .text([trimmed]),
                subType: .systemReminder
            )))
        case .queuedPrompt:
            let text = extractQueuedPromptText(line.attachment?.prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            ctx.entries.append(.user(makeUserEntry(
                id: id,
                timestamp: ts,
                promptId: line.promptId,
                text: text,
                wasQueued: true,
                isQueuedPending: false
            )))
        case .planModeEntered, .planModeExited, .planModeReentered:
            let phase: SystemEntry.PlanModePhase = {
                switch kind {
                case .planModeEntered:    return .entered
                case .planModeExited:     return .exited
                case .planModeReentered:  return .reentered
                default:                  return .entered
                }
            }()
            let phaseName: String = {
                switch phase {
                case .entered:
                    return String(
                        localized: "agentXray.entry.planMode.entered",
                        defaultValue: "Plan mode entered",
                        bundle: .module
                    )
                case .exited:
                    return String(
                        localized: "agentXray.entry.planMode.exited",
                        defaultValue: "Plan mode exited",
                        bundle: .module
                    )
                case .reentered:
                    return String(
                        localized: "agentXray.entry.planMode.reentered",
                        defaultValue: "Plan mode resumed",
                        bundle: .module
                    )
                }
            }()
            let planBasename = line.attachment?.planFilePath.flatMap { path -> String? in
                let last = URL(fileURLWithPath: path).lastPathComponent
                return last.isEmpty ? nil : last
            }
            ctx.entries.append(.system(SystemEntry(
                id: .fromJSONL(id),
                timestamp: ts,
                header: Header(
                    icon: .planMode,
                    name: phaseName,
                    title: planBasename,
                    timestamp: ts
                ),
                body: .empty,
                subType: .planMode(
                    phase: phase,
                    planFilePath: line.attachment?.planFilePath,
                    planExists: line.attachment?.planExists ?? false
                )
            )))
        case .editedTextFile:
            guard let filename = line.attachment?.filename, !filename.isEmpty else { return }
            let basename = URL(fileURLWithPath: filename).lastPathComponent
            let snippet = line.attachment?.snippet
            ctx.entries.append(.system(SystemEntry(
                id: .fromJSONL(id),
                timestamp: ts,
                header: Header(
                    icon: .editedTextFile,
                    name: String(
                        localized: "agentXray.entry.externalEdit.title",
                        defaultValue: "External edit · \(basename)",
                        bundle: .module
                    ),
                    timestamp: ts
                ),
                body: snippet.map { Body.text([$0]) } ?? .empty,
                subType: .editedTextFile(path: filename)
            )))
        }
    }

    private func extractQueuedPromptText(_ content: ClaudeMessageContent?) -> String {
        guard let content else { return "" }
        switch content {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
        }
    }

    private func extractMetaText(_ line: ClaudeJSONLLine) -> String {
        if let body = line.content, !body.isEmpty {
            return body
        }
        return line.message?.content?.firstText() ?? ""
    }

    // MARK: - User / System / Compact / pending-prompt builders

    private func userRoleLabel(isQueued: Bool, isQueuedPending: Bool) -> String {
        if isQueuedPending {
            return String(
                localized: "agentXray.entry.user.queuedLabel",
                defaultValue: "Queued",
                bundle: .module
            )
        }
        return String(
            localized: "agentXray.entry.user.label",
            defaultValue: "User",
            bundle: .module
        )
    }

    private func makeUserEntry(
        id: String,
        timestamp: Date?,
        promptId: String?,
        text: String,
        wasQueued: Bool,
        isQueuedPending: Bool
    ) -> UserEntry {
        let icon: EntryIcon = wasQueued ? .queuedUser : .user
        let preview = singleLinePromptPreview(text)
        let wordCount = wordCount(text)
        let trailing: [TrailingItem] = wordCount > 0
            ? [.wordCount("\(wordCount) words")]
            : []
        return UserEntry(
            id: .fromJSONL(id),
            timestamp: timestamp,
            header: Header(
                icon: icon,
                name: userRoleLabel(isQueued: wasQueued, isQueuedPending: isQueuedPending),
                title: preview.isEmpty ? nil : preview,
                trailing: trailing,
                timestamp: timestamp
            ),
            body: .text([text]),
            promptId: promptId,
            wasQueued: wasQueued,
            isQueuedPending: isQueuedPending
        )
    }

    private func buildPendingUserEntry(_ p: ClaudePendingPrompt) -> UserEntry {
        let preview = singleLinePromptPreview(p.text)
        let wordCount = wordCount(p.text)
        let trailing: [TrailingItem] = wordCount > 0
            ? [.wordCount("\(wordCount) words")]
            : []
        return UserEntry(
            id: .fromJSONL(p.id),
            timestamp: p.timestamp,
            header: Header(
                icon: .queuedUser,
                name: userRoleLabel(isQueued: true, isQueuedPending: true),
                title: preview.isEmpty ? nil : preview,
                trailing: trailing,
                timestamp: p.timestamp
            ),
            body: .text([p.text]),
            promptId: nil,
            wasQueued: true,
            isQueuedPending: true
        )
    }

    private func buildUserEntry(from line: ClaudeJSONLLine, ctx: BuildContext) -> UserEntry? {
        guard let content = line.message?.content else { return nil }
        let rawText: String
        switch content {
        case .text(let str):
            rawText = str.trimmingCharacters(in: .whitespacesAndNewlines)
        case .blocks(let blocks):
            rawText = blocks
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isSlash = rawText.hasPrefix("<command-message>")
            || rawText.hasPrefix("<command-name>")
        let displayText: String
        if isSlash, let slash = ClaudeQueuedPromptResolver.consumedSlashCommandText(line) {
            displayText = slash
        } else {
            displayText = rawText
        }
        let wasQueued = ctx.queuedSlashCommandUuids.contains(line.stableId)
        return makeUserEntry(
            id: line.stableId,
            timestamp: line.timestamp,
            promptId: line.promptId,
            text: displayText,
            wasQueued: wasQueued,
            isQueuedPending: false
        )
    }

    private func buildSystemEntry(from line: ClaudeJSONLLine) -> SystemEntry? {
        let label = String(
            localized: "agentXray.entry.system.localCommand",
            defaultValue: "System",
            bundle: .module
        )
        if line.type == "system", let body = line.content, !body.isEmpty {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return SystemEntry(
                id: .fromJSONL(line.stableId),
                timestamp: line.timestamp,
                header: Header(icon: .system, name: label, timestamp: line.timestamp),
                body: .text([trimmed]),
                subType: .localCommand(input: trimmed)
            )
        }
        guard let content = line.message?.content else { return nil }
        let raw: String
        switch content {
        case .text(let str): raw = str
        case .blocks(let blocks):
            raw = blocks.compactMap { $0.text }.joined(separator: "\n")
        }
        let stripped = stripCommandOutputTags(raw)
        return SystemEntry(
            id: .fromJSONL(line.stableId),
            timestamp: line.timestamp,
            header: Header(icon: .system, name: label, timestamp: line.timestamp),
            body: .text([stripped]),
            subType: .localCommand(input: stripped)
        )
    }

    private func buildCompactEntry(from line: ClaudeJSONLLine) -> CompactEntry {
        let label = String(
            localized: "agentXray.entry.compact.label",
            defaultValue: "Compacted",
            bundle: .module
        )
        let summary: String
        if line.type == "system", let body = line.content, !body.isEmpty {
            summary = body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            summary = line.summary
                ?? extractTextContent(from: line.message?.content)
                ?? ""
        }
        return CompactEntry(
            id: .fromJSONL(line.stableId),
            timestamp: line.timestamp,
            header: Header(icon: .compact, name: label, timestamp: line.timestamp),
            body: .text([summary])
        )
    }

    private func buildBranchLinkEntry(
        branch: ClaudeAbandonedBranch,
        totalRewinds: Int,
        branchEntries: [Entry],
        timestamp: Date
    ) -> SynthesizedEntry {
        let preview = branch.firstPromptPreview ?? String(
            localized: "agentXray.entry.branchLink.noPrompt",
            defaultValue: "(no prompt)",
            bundle: .module
        )
        let title = String(
            localized: "agentXray.entry.branchLink.title",
            defaultValue: "Rewind \(branch.rewindIndex) of \(totalRewinds)",
            bundle: .module
        )
        let subtitle = String(
            localized: "agentXray.entry.branchLink.subtitle",
            defaultValue: "\(branch.entryCount) entries · \(preview)",
            bundle: .module
        )
        return SynthesizedEntry(
            id: .derived(parent: branch.branchRootUuid, kind: "branchLink"),
            timestamp: timestamp,
            header: Header(
                icon: .branchLink,
                name: title,
                title: subtitle,
                timestamp: timestamp
            ),
            body: Body(sections: [.subentries(branchEntries)]),
            kind: .branchLink(
                branchRootUuid: branch.branchRootUuid,
                rewindIndex: branch.rewindIndex,
                totalRewinds: totalRewinds,
                entryCount: branch.entryCount,
                firstPromptPreview: branch.firstPromptPreview
            )
        )
    }

    // MARK: - Build context (per-snapshot mutable state)

    fileprivate struct BuildContext {
        let resolution: ClaudeBranchResolution
        var entries: [Entry] = []
        var pendingTurn: PendingTurn?
        var turnDurations: [String: TurnDurationStamp] = [:]
        var sidechainLinesByParent: [String: [ClaudeJSONLLine]] = [:]
        var emittedDivergencePoints: Set<String> = []
        var queuedSlashCommandUuids: Set<String> = []
        var skillCommandUuids: Set<String> = []
        var abandonedBranchEntriesByRoot: [String: [Entry]] = [:]

        mutating func flushPendingTurn() {
            guard let pending = pendingTurn else { return }
            let stamp: TurnDurationStamp? = pending.lastMessageUuid.flatMap { turnDurations[$0] }

            // Build final tool calls with sidechain transcripts attached.
            let finalToolCalls = pending.toolCallOrder.compactMap { id -> AgentToolCall? in
                guard var call = pending.toolCalls[id] else { return nil }
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
                        sidechainTranscript: buildSidechainEntries(from: lines)
                    )
                }
                return call
            }

            // Build subEntries: [thinking?, ...tools, assistantText?]
            var subEntries: [AgentEntry.SubEntry] = []
            let trimmedThinking = pending.thinkingText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmedThinking.isEmpty {
                subEntries.append(.thinking(ThinkingEntry(
                    id: .derived(parent: pending.id, kind: "thinking"),
                    parentEntryID: .fromJSONL(pending.id),
                    timestamp: pending.startTime,
                    header: Header(
                        icon: .thinking,
                        name: String(
                            localized: "agentXray.entry.thinking.label",
                            defaultValue: "Thinking",
                            bundle: .module
                        ),
                        timestamp: pending.startTime
                    ),
                    body: Body(sections: [.text([pending.thinkingText], style: .thinking)])
                )))
            }
            for call in finalToolCalls {
                let status: ToolEntry.Status = {
                    if call.isError { return .error }
                    if call.result == nil { return .pending }
                    return .ok
                }()
                var sections: [Section] = [.text([call.inputDetail], style: .normal)]
                if let result = call.result {
                    sections.append(.text([result], style: status == .error ? .error : .normal))
                }
                if let sidechain = call.sidechainTranscript, !sidechain.isEmpty {
                    sections.append(.subentries(sidechain))
                }
                subEntries.append(.tool(ToolEntry(
                    id: .fromJSONL(call.id),
                    timestamp: nil,
                    header: Header(
                        icon: .tool(named: call.name),
                        name: call.name,
                        title: call.summary,
                        trailing: call.durationMs.map { [.duration("\($0) ms")] } ?? [],
                        timestamp: nil
                    ),
                    body: Body(sections: sections),
                    toolName: call.name,
                    status: status,
                    durationMs: call.durationMs,
                    subagentType: call.subagentType,
                    teamMemberName: call.teamMemberName,
                    teamName: call.teamName
                )))
            }
            let trimmedAssistant = pending.assistantText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmedAssistant.isEmpty {
                let words = trimmedAssistant.split { $0.isWhitespace || $0.isNewline }.count
                subEntries.append(.assistantText(AssistantTextEntry(
                    id: .derived(parent: pending.id, kind: "assistantText"),
                    parentEntryID: .fromJSONL(pending.id),
                    timestamp: pending.lastTimestamp ?? pending.startTime,
                    header: Header(
                        icon: .agent,
                        name: String(
                            localized: "agentXray.entry.assistantText.label",
                            defaultValue: "Assistant",
                            bundle: .module
                        ),
                        trailing: [.wordCount("\(words) words")],
                        timestamp: pending.lastTimestamp ?? pending.startTime
                    ),
                    fullBody: pending.assistantText,
                    wordCount: words
                )))
            }

            let bodySections: [Section] = subEntries.isEmpty
                ? []
                : [.subentries(subEntries.map(Self.subEntryToTopLevel))]
            let agentLabel = String(
                localized: "agentXray.entry.agent.label.claude",
                defaultValue: "Claude",
                bundle: .module
            )
            var trailing: [TrailingItem] = []
            let totalTokens = pending.usage.inputTokens
                + pending.usage.outputTokens
                + pending.usage.cacheReadTokens
                + pending.usage.cacheCreationTokens
            if totalTokens > 0 {
                trailing.append(.tokenPill(pending.usage))
            }

            entries.append(.agent(AgentEntry(
                id: .fromJSONL(pending.id),
                timestamp: pending.startTime,
                header: Header(
                    icon: .agent,
                    name: agentLabel,
                    label: pending.model.flatMap(ClaudeModelNameMap.friendlyName(for:)),
                    trailing: trailing,
                    timestamp: pending.startTime
                ),
                body: Body(sections: bodySections),
                usage: pending.usage,
                stopReason: pending.stopReason,
                perTurnDurationMs: stamp?.durationMs,
                messageCount: stamp?.messageCount,
                model: pending.model,
                endTime: pending.lastTimestamp,
                subEntries: subEntries
            )))
            pendingTurn = nil
        }

        /// Project a turn's `SubEntry` to a top-level `Entry` for the
        /// body's `.subentries(...)` mirror. Only the renderer's own
        /// per-turn subview consumes this; AgentEntry.subEntries is the
        /// structurally-typed source of truth.
        static func subEntryToTopLevel(_ s: AgentEntry.SubEntry) -> Entry {
            // SubEntry types aren't top-level Entry cases, so we wrap
            // them into a SystemEntry with subType: .other for the
            // body's recursive [.subentries(...)] mirror. The renderer
            // resolves them via AgentEntry.subEntries; this projection
            // is only present so Body.sections is uniform across all
            // entries.
            switch s {
            case .thinking(let t):
                return .system(SystemEntry(
                    id: t.id, timestamp: t.timestamp,
                    header: t.header, body: t.body,
                    subType: .other("thinking")
                ))
            case .tool(let t):
                return .system(SystemEntry(
                    id: t.id, timestamp: t.timestamp,
                    header: t.header, body: t.body,
                    subType: .other("tool")
                ))
            case .assistantText(let a):
                return .system(SystemEntry(
                    id: a.id, timestamp: a.timestamp,
                    header: a.header, body: a.body,
                    subType: .other("assistantText")
                ))
            }
        }

        mutating func collectSidechainLine(_ line: ClaudeJSONLLine) {
            guard let parent = line.parentToolUseID else { return }
            sidechainLinesByParent[parent, default: []].append(line)
        }

        private func buildSidechainEntries(from lines: [ClaudeJSONLLine]) -> [Entry] {
            var sub = ClaudeTranscriptBuilder()
            for line in lines { sub.ingest(line) }
            return sub.transcript()
        }

        mutating func maybeEmitBranchLinks(beforeAdjacentTo line: ClaudeJSONLLine) {
            guard let parent = line.parentUuid else { return }
            for branch in resolution.abandonedBranches
            where branch.divergencePointUuid == parent
                && !emittedDivergencePoints.contains(branch.branchRootUuid) {
                emittedDivergencePoints.insert(branch.branchRootUuid)
                let branchEntries = abandonedBranchEntriesByRoot[branch.branchRootUuid] ?? []
                let totalRewinds = resolution.totalRewinds
                let preview = branch.firstPromptPreview ?? String(
                    localized: "agentXray.entry.branchLink.noPrompt",
                    defaultValue: "(no prompt)",
                    bundle: .module
                )
                let title = String(
                    localized: "agentXray.entry.branchLink.title",
                    defaultValue: "Rewind \(branch.rewindIndex) of \(totalRewinds)",
                    bundle: .module
                )
                let subtitle = String(
                    localized: "agentXray.entry.branchLink.subtitle",
                    defaultValue: "\(branch.entryCount) entries · \(preview)",
                    bundle: .module
                )
                let ts = line.timestamp ?? .distantPast
                entries.append(.synthesized(SynthesizedEntry(
                    id: .derived(parent: branch.branchRootUuid, kind: "branchLink"),
                    timestamp: ts,
                    header: Header(
                        icon: .branchLink,
                        name: title,
                        title: subtitle,
                        timestamp: ts
                    ),
                    body: Body(sections: [.subentries(branchEntries)]),
                    kind: .branchLink(
                        branchRootUuid: branch.branchRootUuid,
                        rewindIndex: branch.rewindIndex,
                        totalRewinds: resolution.totalRewinds,
                        entryCount: branch.entryCount,
                        firstPromptPreview: branch.firstPromptPreview
                    )
                )))
            }
        }
    }

    fileprivate struct PendingTurn {
        var id: String
        var startTime: Date
        var lastTimestamp: Date?
        var lastMessageUuid: String?
        var assistantText: String = ""
        var thinkingText: String = ""
        var toolCalls: [String: AgentToolCall] = [:]
        var toolCallOrder: [String] = []
        var toolStartedAt: [String: Date] = [:]
        var model: String?
        var usage: AgentEntry.TokenUsage = .zero
        var countedUsageMessageIds: Set<String> = []
        var stopReason: String?

        mutating func addUsageOnce(_ usage: ClaudeUsage, identity: String) {
            guard countedUsageMessageIds.insert(identity).inserted else { return }
            self.usage.inputTokens += usage.inputTokens ?? 0
            self.usage.outputTokens += usage.outputTokens ?? 0
            self.usage.cacheReadTokens += usage.cacheReadInputTokens ?? 0
            self.usage.cacheCreationTokens += usage.cacheCreationInputTokens ?? 0
        }
    }

    // MARK: - Classification

    enum Category: Equatable {
        case user
        case system
        case agent
        case compact
        case hardNoise
    }

    func classify(_ line: ClaudeJSONLLine) -> Category {
        if line.isCompactSummary == true { return .compact }
        if line.type == "user" { return classifyUserLine(line) }
        if line.type == "assistant" { return .agent }
        return .hardNoise
    }

    private func classifyUserLine(_ line: ClaudeJSONLLine) -> Category {
        if line.isMeta == true { return .agent }
        guard let content = line.message?.content else { return .hardNoise }

        switch content {
        case .text(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .hardNoise }
            if trimmed == Self.emptyStdout || trimmed == Self.emptyStderr { return .hardNoise }
            if trimmed.hasPrefix(Self.localCommandStdoutTag)
                || trimmed.hasPrefix(Self.localCommandStderrTag) {
                return .system
            }
            for tag in Self.isMetaNullNoiseTags {
                let close = "</" + tag.dropFirst()
                if trimmed.hasPrefix(tag) && trimmed.hasSuffix(close) {
                    return .hardNoise
                }
            }
            if trimmed.hasPrefix("[Request interrupted by user") { return .agent }
            return .user

        case .blocks(let blocks):
            if blocks.count == 1,
               let only = blocks.first,
               only.type == "text",
               only.text?.hasPrefix("[Request interrupted by user") == true {
                return .agent
            }
            if blocks.contains(where: {
                $0.type == "text"
                    && ($0.text?.hasPrefix(Self.localCommandStdoutTag) == true)
            }) {
                return .system
            }
            if blocks.contains(where: { $0.type == "tool_result" }) {
                return .agent
            }
            let hasUserContent = blocks.contains {
                $0.type == "text" || $0.type == "image"
            }
            return hasUserContent ? .user : .hardNoise
        }
    }

    // MARK: - Pending-turn merging

    private func mergeIntoPendingTurn(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        if ctx.pendingTurn == nil {
            ctx.pendingTurn = PendingTurn(
                id: line.stableId,
                startTime: line.timestamp ?? .distantPast
            )
        }
        if let ts = line.timestamp {
            ctx.pendingTurn?.lastTimestamp = ts
        }
        if let uuid = line.uuid {
            ctx.pendingTurn?.lastMessageUuid = uuid
        }

        guard let content = line.message?.content else { return }
        if let model = line.message?.model, ctx.pendingTurn?.model == nil {
            ctx.pendingTurn?.model = model
        }
        if let stopReason = line.message?.stopReason {
            ctx.pendingTurn?.stopReason = stopReason
        }
        if let usage = line.message?.usage {
            let identity = line.message?.id ?? line.uuid ?? line.stableId
            ctx.pendingTurn?.addUsageOnce(usage, identity: identity)
        }

        switch content {
        case .text(let str):
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { appendAssistantText(trimmed, ctx: &ctx) }
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
        guard ctx.pendingTurn != nil else { return }
        if !ctx.pendingTurn!.assistantText.isEmpty {
            ctx.pendingTurn!.assistantText.append("\n")
        }
        ctx.pendingTurn!.assistantText.append(text)
    }

    private func appendThinkingText(_ text: String, ctx: inout BuildContext) {
        guard ctx.pendingTurn != nil else { return }
        if !ctx.pendingTurn!.thinkingText.isEmpty {
            ctx.pendingTurn!.thinkingText.append("\n")
        }
        ctx.pendingTurn!.thinkingText.append(text)
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
        if ctx.pendingTurn?.toolCalls[id] == nil {
            ctx.pendingTurn?.toolCallOrder.append(id)
        }
        ctx.pendingTurn?.toolCalls[id] = call
        if let timestamp {
            ctx.pendingTurn?.toolStartedAt[id] = timestamp
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
                  let started = ctx.pendingTurn?.toolStartedAt[id] else { return nil }
            let delta = timestamp.timeIntervalSince(started)
            return delta >= 0 ? Int(delta * 1000) : nil
        }()
        if let existing = ctx.pendingTurn?.toolCalls[id] {
            ctx.pendingTurn?.toolCalls[id] = AgentToolCall(
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
            if ctx.pendingTurn?.toolCalls[id] == nil {
                ctx.pendingTurn?.toolCallOrder.append(id)
            }
            ctx.pendingTurn?.toolCalls[id] = synthetic
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

    static func summarizeToolInput(name: String, input: ClaudeJSONValue?) -> String {
        guard let input else { return "" }
        guard case .object(let obj) = input else { return input.displayString }

        switch name {
        case "Read", "Edit", "Write", "MultiEdit":
            if case .string(let path)? = obj["file_path"] { return path }
        case "Bash":
            if case .string(let cmd)? = obj["command"] {
                return truncated(cmd, max: ClaudeRenderConsts.toolSummaryMaxChars)
            }
        case "Grep", "Glob":
            if case .string(let pat)? = obj["pattern"] { return pat }
        case "Task":
            if case .string(let desc)? = obj["description"] { return desc }
            if case .string(let prompt)? = obj["prompt"] {
                return truncated(prompt, max: ClaudeRenderConsts.toolSummaryMaxChars)
            }
        case "WebFetch", "WebSearch":
            if case .string(let url)? = obj["url"] ?? obj["query"] { return url }
        default:
            break
        }
        return obj.map { "\($0.key)=\($0.value.displayString)" }.sorted().first ?? ""
    }

    static func flattenToolResult(_ value: ClaudeJSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .array(let arr):
            return arr.compactMap { item -> String? in
                if case .object(let obj) = item,
                   case .string(let s)? = obj["text"] { return s }
                return nil
            }.joined(separator: "\n")
        default:
            return value.displayString
        }
    }

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
                rendered = truncated(s, max: ClaudeRenderConsts.flattenedResultMaxChars)
            case .null, .bool, .int, .double:
                rendered = value.displayString
            case .array, .object:
                rendered = truncated(
                    value.displayString,
                    max: ClaudeRenderConsts.toolInputValueMaxChars
                )
            }
            lines.append("\(key): \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

    static func extractSubagentType(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["subagent_type"] else { return nil }
        return s
    }

    static func extractTeamMemberName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["name"] else { return nil }
        return s
    }

    static func extractTeamName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["team_name"] else { return nil }
        return s
    }

    /// Hard length cap with `…` ellipsis. Used for inline tool-input
    /// JSON rendering where unbounded object/array dumps would blow up
    /// row height. Distinct concern from user-prompt preview, which
    /// dynamically truncates at the view layer via `.truncationMode(.tail)`.
    static func truncated(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
