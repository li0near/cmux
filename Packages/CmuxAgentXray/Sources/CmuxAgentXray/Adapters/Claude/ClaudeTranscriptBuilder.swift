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

        var ctx = BuildContext(resolution: branchResolution, logger: logger)
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
            ctx.entries.append(.synthesized(Self.makeBranchLinkEntry(
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
            ctx.entries.append(.user(makeUserEntry(
                id: pending.id,
                timestamp: pending.timestamp,
                promptId: nil,
                text: pending.text,
                queuedState: .pending
            )))
        }

        return ctx.entries
    }

    /// Recursively build entries for an abandoned-branch transcript.
    /// Forwards `self.logger` so spec-only-not-corpus warnings emitted
    /// during `buildToolResultSections` aren't silently dropped on the
    /// nested transcript path.
    private func buildAbandonedBranchEntries(from lines: [ClaudeJSONLLine]) -> [Entry] {
        var sub = ClaudeTranscriptBuilder(logger: logger)
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
        let body = line.metaBody

        switch kind {
        case .recap:
            let recapBody = (line.content ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
            if recapBody.isEmpty { return }
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .recap,
                name: Self.loc("agentXray.entry.recap.title", "Recap"),
                body: .text([recapBody]),
                subType: .recap
            ))
        case .prLink:
            guard let prNumber = line.prNumber,
                  let prUrl = line.prUrl,
                  let prRepository = line.prRepository else { return }
            ctx.entries.append(.synthesized(SynthesizedEntry(
                id: .derived(parent: id, kind: "prLink"),
                header: Header(
                    icon: .prLink,
                    title: Self.loc(
                        "agentXray.entry.prLink.title",
                        "PR #\(prNumber) · \(prRepository)"
                    ),
                    timeMarker: .clock(ts)
                ),
                body: .empty,
                kind: .prLink(prNumber: prNumber, url: prUrl, repository: prRepository)
            )))
        case .continueResume:
            return
        case .slashCmdInput(let name, let args):
            if ctx.queuedSlashCommandUuids.contains(line.stableId) {
                let text = ClaudeQueuedPromptResolver.consumedSlashCommandText(line) ?? body
                ctx.entries.append(.user(makeUserEntry(
                    id: id,
                    timestamp: ts,
                    promptId: line.promptId,
                    text: text,
                    queuedState: .consumed
                )))
            } else {
                let title = args.map { "/\(name) \($0)" } ?? "/\(name)"
                ctx.entries.append(Self.makeSystemEntry(
                    id: id, ts: ts, icon: .slashCommand,
                    title: title,
                    body: .empty,
                    subType: .slashCmdInput(name: name, args: args)
                ))
            }
        case .slashCmdOutput(let b, let isStderr):
            if b.isEmpty { return }
            let label = isStderr
                ? Self.loc("agentXray.entry.slashCmd.stderr", "Slash command stderr")
                : Self.loc("agentXray.entry.slashCmd.output", "Slash command output")
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .system, name: label,
                body: Body(sections: [.text([b], style: isStderr ? .error : .normal)]),
                subType: .slashCmdOutput(isStderr: isStderr)
            ))
        case .localCommandCaveat:
            return
        case .systemReminder(let b):
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .systemReminder,
                name: Self.loc("agentXray.entry.systemReminder.title", "System reminder"),
                body: .text([b]),
                subType: .systemReminder
            ))
        case .skill(let name, let basePath, let b):
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .skill,
                name: Self.loc("agentXray.entry.skill.title", "Skill: \(name)"),
                title: basePath,
                body: .text([b]),
                subType: .skill(name: name, basePath: basePath)
            ))
        case .contextUsage(let b):
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .contextInfo,
                name: Self.loc("agentXray.entry.contextUsage.title", "Context usage"),
                body: .text([b]),
                subType: .contextUsage
            ))
        case .unknownMeta:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .systemReminder,
                name: Self.loc("agentXray.entry.systemReminder.title", "System reminder"),
                body: .text([trimmed]),
                subType: .systemReminder
            ))
        case .queuedPrompt:
            let text = (line.attachment?.prompt?.firstText() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            ctx.entries.append(.user(makeUserEntry(
                id: id,
                timestamp: ts,
                promptId: line.promptId,
                text: text,
                queuedState: .consumed
            )))
        case .planModeEntered, .planModeExited, .planModeReentered:
            let (phase, phaseName) = Self.planModeMetadata(kind)
            let planBasename = line.attachment?.planFilePath.flatMap { path -> String? in
                let last = URL(fileURLWithPath: path).lastPathComponent
                return last.isEmpty ? nil : last
            }
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .planMode,
                name: phaseName,
                title: planBasename,
                body: .empty,
                subType: .planMode(
                    phase: phase,
                    planFilePath: line.attachment?.planFilePath,
                    planExists: line.attachment?.planExists ?? false
                )
            ))
        case .editedTextFile:
            guard let filename = line.attachment?.filename, !filename.isEmpty else { return }
            let basename = URL(fileURLWithPath: filename).lastPathComponent
            let snippet = line.attachment?.snippet
            ctx.entries.append(Self.makeSystemEntry(
                id: id, ts: ts, icon: .editedTextFile,
                name: Self.loc("agentXray.entry.externalEdit.title", "External edit · \(basename)"),
                body: snippet.map { Body.text([$0]) } ?? .empty,
                subType: .editedTextFile(path: filename)
            ))
        }
    }

    /// Phase + localized phaseName for the three plan-mode special kinds.
    /// Pulled out of `emitSpecial` so the per-kind switch isn't duplicated.
    private static func planModeMetadata(
        _ kind: ClaudeSpecialKind
    ) -> (SystemEntry.PlanModePhase, String) {
        switch kind {
        case .planModeEntered:
            return (.entered, loc("agentXray.entry.planMode.entered", "Plan mode entered"))
        case .planModeExited:
            return (.exited, loc("agentXray.entry.planMode.exited", "Plan mode exited"))
        case .planModeReentered:
            return (.reentered, loc("agentXray.entry.planMode.reentered", "Plan mode resumed"))
        default:
            return (.entered, loc("agentXray.entry.planMode.entered", "Plan mode entered"))
        }
    }

    // MARK: - User / System / Compact / pending-prompt builders

    private func userRoleLabel(_ state: UserEntry.QueuedState) -> String {
        if state == .pending {
            return Self.loc("agentXray.entry.user.queuedLabel", "Queued")
        }
        return Self.loc("agentXray.entry.user.label", "User")
    }

    /// Construct a `UserEntry` from a per-block ``Section`` array.
    /// Used directly by ``buildUserEntry(from:ctx:)`` so user-pasted
    /// `image` blocks survive into the body (the legacy text-only
    /// shorthand silently dropped them at the `joinText` filter).
    ///
    /// `header.title` (preview) and the trailing word-count pill are
    /// derived from the **text-only** projection of the sections —
    /// images don't contribute to either.
    private func makeUserEntry(
        id: String,
        timestamp: Date?,
        promptId: String?,
        sections: [Section],
        queuedState: UserEntry.QueuedState
    ) -> UserEntry {
        let text = sections.compactMap { section -> String? in
            if case .text(let blocks, _) = section { return blocks.joined(separator: "\n") }
            return nil
        }.joined(separator: "\n")
        let icon: EntryIcon = (queuedState == .none) ? .user : .queuedUser
        let preview = singleLinePromptPreview(text)
        let wordCount = wordCount(text)
        let trailing: [TrailingItem] = wordCount > 0
            ? [.wordCount("\(wordCount) words")]
            : []
        return UserEntry(
            id: .fromJSONL(id),
            header: Header(
                icon: icon,
                name: userRoleLabel(queuedState),
                title: preview.isEmpty ? nil : preview,
                trailing: trailing,
                timeMarker: timestamp.map { .clock($0) }
            ),
            body: Body(sections: sections),
            promptId: promptId,
            queuedState: queuedState
        )
    }

    /// Text-shorthand convenience for the four call sites that only
    /// have a single string (queued prompts, slash-command consumed,
    /// system-side transformations). Wraps the text in a single
    /// `.text([s], .normal)` section before calling the canonical
    /// section-bearing form.
    private func makeUserEntry(
        id: String,
        timestamp: Date?,
        promptId: String?,
        text: String,
        queuedState: UserEntry.QueuedState
    ) -> UserEntry {
        makeUserEntry(
            id: id,
            timestamp: timestamp,
            promptId: promptId,
            sections: [.text([text], style: .normal)],
            queuedState: queuedState
        )
    }

    private func buildUserEntry(from line: ClaudeJSONLLine, ctx: BuildContext) -> UserEntry? {
        guard line.message?.content != nil else { return nil }
        let sections = UserContentParser.parse(from: line.message?.content)
        // Slash-command detection runs against the **first text block** —
        // a slash-command line never carries multiple text blocks, so
        // `firstText()` is the canonical probe.
        let rawText = (line.message?.content?.firstText() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isSlash = rawText.hasPrefix("<command-message>")
            || rawText.hasPrefix("<command-name>")
        let wasQueued = ctx.queuedSlashCommandUuids.contains(line.stableId)
        if isSlash, let slash = ClaudeQueuedPromptResolver.consumedSlashCommandText(line) {
            // Slash-command consumed: discard any non-text blocks (none
            // expected) and rebuild as a single text section.
            return makeUserEntry(
                id: line.stableId,
                timestamp: line.timestamp,
                promptId: line.promptId,
                text: slash,
                queuedState: wasQueued ? .consumed : .none
            )
        }
        return makeUserEntry(
            id: line.stableId,
            timestamp: line.timestamp,
            promptId: line.promptId,
            sections: sections,
            queuedState: wasQueued ? .consumed : .none
        )
    }

    private func buildSystemEntry(from line: ClaudeJSONLLine) -> SystemEntry? {
        let label = Self.loc("agentXray.entry.system.localCommand", "System")
        let raw: String
        if line.type == "system", let body = line.content, !body.isEmpty {
            raw = body
        } else if let content = line.message?.content {
            raw = content.allText()
        } else {
            return nil
        }
        let stripped = stripCommandOutputTags(raw)
        return SystemEntry(
            id: .fromJSONL(line.stableId),
            header: Header(icon: .system, name: label, timeMarker: line.timestamp.map { .clock($0) }),
            body: .text([stripped]),
            subType: .localCommand(input: stripped)
        )
    }

    private func buildCompactEntry(from line: ClaudeJSONLLine) -> CompactEntry {
        let label = Self.loc("agentXray.entry.compact.label", "Compacted")
        let summary: String
        if line.type == "system", let body = line.content, !body.isEmpty {
            summary = body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            summary = line.summary
                ?? (line.message?.content?.allText() ?? "")
        }
        return CompactEntry(
            id: .fromJSONL(line.stableId),
            header: Header(icon: .compact, name: label, timeMarker: line.timestamp.map { .clock($0) }),
            body: .text([summary])
        )
    }

    /// Build a `SynthesizedEntry.branchLink` for one abandoned branch.
    /// Used by both the pre-pass orphan-branch emit (in `transcript()`)
    /// and per-line per-divergence emit (in
    /// `BuildContext.maybeEmitBranchLinks`).
    static func makeBranchLinkEntry(
        branch: ClaudeAbandonedBranch,
        totalRewinds: Int,
        branchEntries: [Entry],
        timestamp: Date
    ) -> SynthesizedEntry {
        let preview = branch.firstPromptPreview ?? loc(
            "agentXray.entry.branchLink.noPrompt", "(no prompt)"
        )
        let title = loc(
            "agentXray.entry.branchLink.title",
            "Rewind \(branch.rewindIndex) of \(totalRewinds)"
        )
        let subtitle = loc(
            "agentXray.entry.branchLink.subtitle",
            "\(branch.entryCount) entries · \(preview)"
        )
        return SynthesizedEntry(
            id: .derived(parent: branch.branchRootUuid, kind: "branchLink"),
            header: Header(
                icon: .branchLink,
                name: title,
                title: subtitle,
                timeMarker: .clock(timestamp)
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
        /// Forwarded from the parent `ClaudeTranscriptBuilder` so
        /// recursive sub-builders (sidechain transcripts) carry the
        /// same logger and don't silently drop the spec-only-not-corpus
        /// warnings emitted by `buildToolResultSections`.
        let logger: any AgentXrayLogger
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

            // Walk the arrival-order sub-entry log. Text events
            // (thinking / assistant) interleave with tool calls in
            // the order Claude emitted them — preserving the
            // chronological "narrate → tool → narrate → tool" flow.
            // (Predecessor builder collapsed all narration into one
            // block and forced [thinking?, …tools, assistantText?]
            // order.) Sidechain transcripts attach inline as we go.
            var subEntries: [AgentEntry.SubEntry] = []
            let parentEntryID = EntryID.fromJSONL(pending.id)
            for slot in pending.subEntries {
                switch slot {
                case .text(let kind, let text, let ts, let id):
                    let fallbackTs = (kind == .assistant)
                        ? (ts ?? pending.lastTimestamp ?? pending.startTime)
                        : (ts ?? pending.startTime)
                    subEntries.append(.text(ClaudeTranscriptBuilder.makeTextSubEntry(
                        kind: kind,
                        text: text,
                        timestamp: fallbackTs,
                        id: id,
                        parentEntryID: parentEntryID
                    )))
                case .tool(var call, _):
                    if (call.name == "Task" || call.name == "Agent"),
                       let lines = sidechainLinesByParent[call.id] {
                        call = call.withSidechain(buildSidechainEntries(from: lines))
                    }
                    let status: ToolEntry.Status = {
                        if call.isError { return .error }
                        if call.result == nil { return .pending }
                        return .ok
                    }()
                    var sections: [Section]
                    if let diffSections = call.diffSections {
                        sections = diffSections
                    } else {
                        sections = [.text([call.inputDetail], style: .normal)]
                    }
                    if let resultSections = call.result {
                        sections.append(contentsOf: resultSections)
                    }
                    if let sidechain = call.sidechainTranscript, !sidechain.isEmpty {
                        sections.append(.subentries(sidechain))
                    }
                    let parsed = MCPToolNameParser.parse(call.name)
                    subEntries.append(.tool(ToolEntry(
                        id: .fromJSONL(call.id),
                        parentEntryID: parentEntryID,
                        header: Header(
                            icon: .tool(named: call.name),
                            name: parsed.display,
                            title: call.summary,
                            timeMarker: call.durationMs.map { .duration($0) }
                        ),
                        body: Body(sections: sections),
                        status: status,
                        durationMs: call.durationMs,
                        subagentType: call.subagentType,
                        teamMemberName: call.teamMemberName,
                        teamName: call.teamName,
                        mcpServer: call.mcpServer,
                        inputFilePath: call.inputFilePath
                    )))
                }
            }

            // AgentEntry's body is intentionally empty: the renderer
            // walks `subEntries` directly via `AgentEntryView` (which
            // bypasses the generic `EntryBodyView` / `EntryComputedCache`
            // dispatch entirely). The earlier body.sections mirror via
            // `subEntryToTopLevel` was dead computation — the cache
            // signature it contributed to was never read for AgentEntry.
            let agentLabel = ClaudeTranscriptBuilder.loc("agentXray.entry.agent.label.claude", "Claude")
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
                header: Header(
                    icon: .agent,
                    name: agentLabel,
                    label: pending.model.flatMap(ClaudeModelNameMap.friendlyName(for:)),
                    trailing: trailing,
                    timeMarker: .clock(pending.startTime)
                ),
                body: Body(sections: []),
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

        mutating func collectSidechainLine(_ line: ClaudeJSONLLine) {
            guard let parent = line.parentToolUseID else { return }
            sidechainLinesByParent[parent, default: []].append(line)
        }

        private func buildSidechainEntries(from lines: [ClaudeJSONLLine]) -> [Entry] {
            // Forward `logger` so spec-only-not-corpus warnings emitted
            // during nested `buildToolResultSections` aren't silently
            // dropped on the sub-agent transcript path.
            var sub = ClaudeTranscriptBuilder(logger: logger)
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
                let ts = line.timestamp ?? .distantPast
                entries.append(.synthesized(ClaudeTranscriptBuilder.makeBranchLinkEntry(
                    branch: branch,
                    totalRewinds: resolution.totalRewinds,
                    branchEntries: branchEntries,
                    timestamp: ts
                )))
            }
        }
    }

    fileprivate struct PendingTurn {
        var id: String
        var startTime: Date
        var lastTimestamp: Date?
        var lastMessageUuid: String?
        /// Sub-entries as they arrive — text blocks and tool calls
        /// interleaved in JSONL arrival order. Tool calls mutate in
        /// place when their `tool_result` lands (located via
        /// `toolIndexByID`). `flushPendingTurn` walks this once.
        var subEntries: [PendingSubEntry] = []
        /// Index into `subEntries` for each in-flight tool, keyed by
        /// `tool_use_id`. Lets `tool_result` find its target in O(1)
        /// without a separate ordering list.
        var toolIndexByID: [String: Int] = [:]
        var thinkingCounter: Int = 0
        var assistantTextCounter: Int = 0
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

    /// One slot in `PendingTurn.subEntries`. Tool calls carry their
    /// own mutable `AgentToolCall` accumulator + the start timestamp
    /// for duration computation; text events are append-only and
    /// inert after construction.
    fileprivate enum PendingSubEntry {
        case text(kind: TextSubEntry.Kind, text: String, timestamp: Date?, id: EntryID)
        case tool(call: AgentToolCall, startedAt: Date?)
    }

    // MARK: - Classification

    enum Category: Equatable {
        case user
        case system
        case agent
        case hardNoise
    }

    /// Per-content refinement of a `.render(.user)` routing decision.
    /// `UserLineDispatcher` already filtered out `isCompactSummary` and
    /// `isMeta==true` lines by the time this function runs (those route
    /// to `.render(.compact)` and `.renderSpecial(...)` respectively),
    /// so this only handles the residual content-shape sniffs.
    func classify(_ line: ClaudeJSONLLine) -> Category {
        if line.type == "user" { return classifyUserLine(line) }
        if line.type == "assistant" { return .agent }
        return .hardNoise
    }

    private func classifyUserLine(_ line: ClaudeJSONLLine) -> Category {
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
            if !trimmed.isEmpty {
                appendTextEvent(kind: .assistant, trimmed, timestamp: line.timestamp, ctx: &ctx)
            }
        case .blocks(let blocks):
            for block in blocks {
                switch block.type {
                case "text":
                    if let t = block.text {
                        appendTextEvent(kind: .assistant, t, timestamp: line.timestamp, ctx: &ctx)
                    }
                case "thinking":
                    if let t = block.thinking {
                        appendTextEvent(kind: .thinking, t, timestamp: line.timestamp, ctx: &ctx)
                    }
                case "tool_use":
                    appendToolUse(block, timestamp: line.timestamp, ctx: &ctx)
                case "tool_result":
                    attachToolResult(block, timestamp: line.timestamp, ctx: &ctx)
                case "image":
                    // VERIFY-CORPUS-2026-06-07: 0 hits for assistant-emitted
                    // image blocks past this date. Spec-allowed (Anthropic
                    // Messages API) but never emitted by Claude Code in
                    // practice — real images flow back via tool_result
                    // (e.g. Playwright `browser_take_screenshot`) or via
                    // top-level user paste, both handled in their own
                    // paths. If this warning surfaces, design a proper
                    // assistant-image emission rather than re-instating
                    // the legacy "[image]" placeholder text.
                    logger.warning(
                        "ClaudeTranscriptBuilder: assistant-emitted image block surfaced "
                        + "(spec-only-not-corpus). Skipping; design appendImageEvent if this becomes common."
                    )
                default:
                    break
                }
            }
        }
    }

    /// Append one text event to the pending turn — used for both
    /// thinking and final assistant text blocks. The `kind` discriminator
    /// drives which per-kind counter is bumped (so the derived id
    /// `"thinking-N"` / `"assistantText-N"` keeps its kind tag) and is
    /// stored on the event for the flush-time projection.
    private func appendTextEvent(
        kind: TextSubEntry.Kind,
        _ text: String,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard ctx.pendingTurn != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let suffix: String
        switch kind {
        case .thinking:
            let idx = ctx.pendingTurn!.thinkingCounter
            ctx.pendingTurn!.thinkingCounter += 1
            suffix = "thinking-\(idx)"
        case .assistant:
            let idx = ctx.pendingTurn!.assistantTextCounter
            ctx.pendingTurn!.assistantTextCounter += 1
            suffix = "assistantText-\(idx)"
        }
        let id = EntryID.derived(parent: ctx.pendingTurn!.id, kind: suffix)
        ctx.pendingTurn!.subEntries.append(
            .text(kind: kind, text: trimmed, timestamp: timestamp, id: id)
        )
    }

    private func appendToolUse(
        _ block: ClaudeContentBlock,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let id = block.id, let name = block.name else { return }
        let teamMemberName = ToolInputParser.teamMemberName(name: name, input: block.input)
        let teamName = ToolInputParser.teamName(name: name, input: block.input)
        let mcpServer = MCPToolNameParser.parse(name).server
        let diffSections = ToolInputParser.diffSections(name: name, input: block.input)
        let call = AgentToolCall(
            id: id,
            name: name,
            summary: ToolInputParser.summarize(name: name, input: block.input),
            inputDetail: ToolInputParser.format(block.input),
            result: nil,
            isError: false,
            subagentType: ToolInputParser.subagentType(name: name, input: block.input),
            teamMemberName: teamMemberName,
            teamName: teamName,
            mcpServer: mcpServer,
            durationMs: nil,
            sidechainTranscript: nil,
            inputFilePath: ToolInputParser.filePath(name: name, input: block.input),
            diffSections: diffSections
        )
        guard ctx.pendingTurn != nil else { return }
        // Only register a fresh tool slot if this id hasn't been seen
        // (defensive — duplicate tool_use blocks for one id are
        // unexpected but ignoring repeats keeps order monotonic).
        if ctx.pendingTurn!.toolIndexByID[id] == nil {
            let index = ctx.pendingTurn!.subEntries.count
            ctx.pendingTurn!.subEntries.append(.tool(call: call, startedAt: timestamp))
            ctx.pendingTurn!.toolIndexByID[id] = index
        } else {
            // Re-emitted tool_use — overwrite the call payload but
            // keep the original index/order.
            let index = ctx.pendingTurn!.toolIndexByID[id]!
            ctx.pendingTurn!.subEntries[index] = .tool(call: call, startedAt: timestamp)
        }
    }

    private func attachToolResult(
        _ block: ClaudeContentBlock,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let id = block.toolUseId, ctx.pendingTurn != nil else { return }
        let isError = block.isError ?? false
        let resultSections = ToolResultParser.parse(
            block.toolResultContent,
            isError: isError,
            logger: logger
        )
        if let index = ctx.pendingTurn!.toolIndexByID[id],
           case .tool(let existing, let startedAt) = ctx.pendingTurn!.subEntries[index] {
            let durationMs = startedAt.flatMap { started -> Int? in
                guard let timestamp else { return nil }
                let delta = timestamp.timeIntervalSince(started)
                return delta >= 0 ? Int(delta * 1000) : nil
            }
            let updated = existing.withResult(resultSections, isError: isError, durationMs: durationMs)
            ctx.pendingTurn!.subEntries[index] = .tool(call: updated, startedAt: startedAt)
        } else {
            // Synthetic — tool_result arrived without a prior tool_use.
            let synthetic = AgentToolCall(
                id: id,
                name: "(tool result)",
                summary: "",
                inputDetail: "",
                result: resultSections,
                isError: isError,
                subagentType: nil,
                teamMemberName: nil,
                teamName: nil,
                durationMs: nil,
                sidechainTranscript: nil
            )
            let index = ctx.pendingTurn!.subEntries.count
            ctx.pendingTurn!.subEntries.append(.tool(call: synthetic, startedAt: nil))
            ctx.pendingTurn!.toolIndexByID[id] = index
        }
    }

    // MARK: - Helpers

    /// Construct a `TextSubEntry` for either thinking or assistant
    /// kind. The two events share identical structure aside from
    /// kind-specific icon, localized label, and body `TextStyle`; the
    /// helper holds that mapping in one place.
    private static func makeTextSubEntry(
        kind: TextSubEntry.Kind,
        text: String,
        timestamp: Date,
        id: EntryID,
        parentEntryID: EntryID
    ) -> TextSubEntry {
        let words = wordCount(text)
        let icon: EntryIcon = (kind == .thinking) ? .thinking : .assistantText
        let style: TextStyle = (kind == .thinking) ? .thinking : .normal
        let name: String = (kind == .thinking)
            ? loc("agentXray.entry.thinking.label", "Thinking")
            : loc("agentXray.entry.assistantText.label", "Assistant")
        return TextSubEntry(
            kind: kind,
            id: id,
            parentEntryID: parentEntryID,
            header: Header(
                icon: icon,
                name: name,
                trailing: [.wordCount("\(words) words")],
                timeMarker: .clock(timestamp)
            ),
            body: Body(sections: [.text([text], style: style)]),
            wordCount: words
        )
    }

    /// Localization shorthand. One-line replacement for the longer
    /// `String(localized:defaultValue:bundle:)` incantation; every
    /// agent-X-ray-package localization key lives in `Bundle.module`.
    private static func loc(_ key: StaticString, _ fallback: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: fallback, bundle: .module)
    }

    /// Construct a `SystemEntry`-wrapped `Entry` from per-emit-case
    /// fields. The constant boilerplate (`.fromJSONL` id, `.clock(ts)`
    /// time marker, header glue) folds in here so each `emitSpecial`
    /// arm states only the per-kind data.
    private static func makeSystemEntry(
        id: String,
        ts: Date,
        icon: EntryIcon?,
        name: String? = nil,
        title: String? = nil,
        body: Body,
        subType: SystemEntry.SubType
    ) -> Entry {
        .system(SystemEntry(
            id: .fromJSONL(id),
            header: Header(
                icon: icon,
                name: name,
                title: title,
                timeMarker: .clock(ts)
            ),
            body: body,
            subType: subType
        ))
    }

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
}
