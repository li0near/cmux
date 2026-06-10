import Foundation

/// Builds an `[Entry]` transcript from a stream of raw Claude JSONL
/// lines.
///
/// **Per-line dispatch (post-G6).** Each JSONL line stands on its
/// own. There is no "current turn" pointer, no skeleton variable, and
/// no close-turn boundary. The dispatcher routes via
/// ``ClaudeLineDispatcher/route(_:logger:)`` and mutates the
/// ``Transcript`` document — append top-level (top-level kinds),
/// resolve-then-fold blocks (assistant lines), `mutate` (tool_result,
/// turn_duration), or alias-only (skipped lines).
///
/// **Universal alias rule.** Every JSONL line uuid lands in
/// ``Transcript/index`` — either as a real entry id (when the line's
/// own append registers it) or as an alias mapping to its parent's
/// resolved path (chained assistant lines, tool_result-mutating user
/// lines, turn_duration lines, skipped decorators). Children resolve
/// in O(1) without re-walking the JSONL chain.
///
/// **Out-of-order pool.** Lines whose `parentUuid` isn't yet in
/// `index` are parked in `awaitingParent[parentUuid]` (single-child
/// per parent uuid; corpus 0/731 with 2+). Drain triggers on every
/// successful uuid registration.
///
/// **Pending-prompt FIFO.** `queue-operation enqueue` appends a
/// `.pending` UserEntry top-level and pushes its `(id, text)` onto
/// `pendingPromptQueue`. Both `attachment.queued_command` and
/// slash-cmd input lines pop the matching head text and replace the
/// `.pending` entry with a fresh `.consumed` UserEntry. If never
/// consumed, the `.pending` entry stays — same end-state as the
/// pre-G6 tail-emit, achieved without a post-loop step.
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
        var ctx = BuildContext(logger: logger)
        for line in rawLines {
            dispatch(line, ctx: &ctx)
        }
        return ctx.root.entries
    }

    // MARK: - Build context (per-snapshot mutable state)

    /// Per-snapshot mutable state. Four fields — every per-turn
    /// abstraction from the legacy PendingTurn pipeline is gone.
    fileprivate struct BuildContext {
        /// Forwarded from the parent builder so re-entrant code paths
        /// inherit the same logger.
        let logger: any AgentXrayLogger
        /// The Phase G transcript document. Source of truth —
        /// ``transcript()`` returns `root.entries`.
        var root = Transcript()
        /// File-order FIFO of pending queued prompts. Each entry is a
        /// tuple of `(id, text)`: the id of the `.pending` UserEntry
        /// sitting in `root.entries`, and the text used for matching
        /// against later slash-cmd / attachment.queued_command
        /// consumption events.
        var pendingPromptQueue: [(id: EntryID, text: String)] = []
        /// Lines whose JSONL parent uuid isn't yet in `root.index`.
        /// Keyed on the missing parentUuid; populated when a child
        /// arrives before its parent (parallel-tool-call out-of-order
        /// — corpus survey said ~0.04% of lines, single-child per
        /// parent uuid, but a 2026-06-09 dogfood session hit a
        /// real 2+-child case so this is an array now). Drained
        /// FIFO whenever a uuid is newly registered (real append
        /// or alias).
        var awaitingParent: [String: [ClaudeJSONLLine]] = [:]
    }

    // MARK: - Top-level dispatch

    private func dispatch(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        // Out-of-order gate. parent uuid not in index → park in pool
        // until parent arrives. The drain re-runs `dispatch` on every
        // popped child, which then resolves cleanly. Multi-child
        // buckets are rare but real (a 2026-06-09 dogfood session
        // hit one) — pool stores an array so all waiting children
        // drain in arrival order.
        if let parentUuid = line.parentUuid, !parentUuid.isEmpty,
           ctx.root.path(of: .fromJSONL(parentUuid)) == nil {
            ctx.awaitingParent[parentUuid, default: []].append(line)
            return
        }

        // `system.subtype: turn_duration` short-circuits routing —
        // it's a mutation against the AgentEntry indicated by the
        // line's parent walk, not a renderable entry. Heterogeneous
        // parent types in the corpus (assistant 65.7%,
        // system/stop_hook_summary 33.8%, user/tool_result 0.4%) all
        // alias-resolve to the right AgentEntry path uniformly.
        if line.type == "system", line.subtype == "turn_duration" {
            applyTurnDuration(line, ctx: &ctx)
            registerLineAlias(line, ctx: &ctx)
            drainAwaitingParent(byNewlyRegisteredUuid: line.uuid, ctx: &ctx)
            return
        }

        let routing = ClaudeLineDispatcher.route(line, logger: logger)
        perform(routing: routing, line: line, ctx: &ctx)

        registerLineAlias(line, ctx: &ctx)
        drainAwaitingParent(byNewlyRegisteredUuid: line.uuid, ctx: &ctx)
    }

    private func perform(
        routing: ClaudeLineRouting,
        line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        switch routing {
        case .skip:
            return
        case .queueOperation(let text):
            handleQueueEnqueue(text: text, line: line, ctx: &ctx)
        case .render(let kind):
            switch kind {
            case .compact:
                ctx.root.append(parent: nil, entry: .compact(buildCompactEntry(from: line)))
            case .user:
                handleUserOrAgentRouting(line: line, ctx: &ctx)
            case .system:
                if let entry = buildSystemEntry(from: line) {
                    ctx.root.append(parent: nil, entry: .system(entry))
                }
            case .agent:
                applyAssistantLine(line, ctx: &ctx)
            }
        case .renderSpecial(let kind):
            emitSpecial(line, kind: kind, ctx: &ctx)
        }
    }

    /// Disambiguate a `.render(.user)` routing — content shape decides
    /// whether the line is a user-typed prompt (top-level UserEntry),
    /// a tool_result-bearing user line (route to assistant arm), or
    /// system-styled local-command output.
    private func handleUserOrAgentRouting(
        line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        switch classify(line) {
        case .user:
            detectAndApplyRewind(line, ctx: &ctx)
            if let entry = buildUserEntry(from: line) {
                ctx.root.append(parent: nil, entry: .user(entry))
            }
        case .system:
            if let entry = buildSystemEntry(from: line) {
                ctx.root.append(parent: nil, entry: .system(entry))
            }
        case .agent:
            applyAssistantLine(line, ctx: &ctx)
        case .hardNoise:
            return
        }
    }

    // MARK: - Universal alias rule

    /// After every line's primary action, register the line's uuid in
    /// the index so future children's parent resolution is O(1). No-op
    /// if the line's own append already registered the uuid (real
    /// entries win).
    ///
    /// Lines whose parent uuid is missing/empty (e.g., session-orphan
    /// metadata, top-level attachments like `hook_success` whose
    /// `parentUuid` is null) still get aliased — at the empty path
    /// `[]` — so their children resolve via the empty-path
    /// fallthrough (pool gate sees `path(of:)` returning
    /// `Optional.some([])`, treats parent as resolved; assistant arm's
    /// `parentPath.first` returns nil and creates a fresh AgentEntry
    /// at top-level). Without this, a single `hook_success` parent
    /// blocks every descendant in cascade and the transcript
    /// renders empty.
    private func registerLineAlias(
        _ line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        let lineId = EntryID.fromJSONL(line.stableId)
        if ctx.root.path(of: lineId) != nil { return }   // covered by real append
        let parentPath: [Int]
        if let parentUuid = line.parentUuid, !parentUuid.isEmpty {
            // Pool gate above guarantees parent is in index when we
            // reach here; the `?? []` is defensive.
            parentPath = ctx.root.path(of: .fromJSONL(parentUuid)) ?? []
        } else {
            parentPath = []
        }
        ctx.root.registerAlias(lineUuid: lineId, path: parentPath)
    }

    /// Drain pool by the freshly-registered uuid. All pooled children
    /// keyed on this uuid are popped in FIFO arrival order and
    /// re-dispatched. Re-dispatching may register new uuids, which
    /// cascades through `dispatch`'s tail call to
    /// `drainAwaitingParent`. Bounded by total file size; terminates.
    private func drainAwaitingParent(
        byNewlyRegisteredUuid uuid: String?,
        ctx: inout BuildContext
    ) {
        guard let uuid,
              let pooled = ctx.awaitingParent.removeValue(forKey: uuid)
        else { return }
        for line in pooled {
            dispatch(line, ctx: &ctx)
        }
    }

    // MARK: - Rewind detection

    /// Detect and apply a rewind. Solo purpose: when a top-level user
    /// prompt's `parentUuid` resolves to a top-level slot K with
    /// trailing entries past K, fold those entries into a synthesized
    /// rewind at slot K+1. No summarization (entry counts, preview
    /// text, "Rewind X of Y" labels). Renders as a single collapsible
    /// "Rewind" entry at top-level by virtue of
    /// ``Transcript/branchOff(at:link:)``.
    private func detectAndApplyRewind(
        _ line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        guard let parentJSONL = line.parentUuid, !parentJSONL.isEmpty
        else { return }
        let parentId = EntryID.fromJSONL(parentJSONL)
        guard let parentPath = ctx.root.path(of: parentId),
              parentPath.count == 1
        else { return }
        // Skip prior `.rewind` siblings at the same divergence point —
        // they were folded by earlier rewinds and stay as siblings, not
        // re-folded into the new rewind. Without this, multi-rewind off
        // the same parent produces visually-nested branches (one rewind
        // wraps the previous, ad infinitum), since `branchOff`'s slice
        // would scoop them up into the new link's subEntries.
        var firstLiveTailSlot = parentPath[0] + 1
        while firstLiveTailSlot < ctx.root.entries.count {
            if case .synthesized(let s) = ctx.root.entries[firstLiveTailSlot],
               case .rewind = s.kind {
                firstLiveTailSlot += 1
                continue
            }
            break
        }
        guard firstLiveTailSlot < ctx.root.entries.count else { return }
        let abandoned = Array(ctx.root.entries[firstLiveTailSlot...])
        guard let firstAbandoned = abandoned.first else { return }
        let firstUuid = firstAbandoned.id.stableString
        let link = SynthesizedEntry(
            id: .derived(parent: firstUuid, kind: "rewind"),
            header: Header(
                icon: .rewind,
                name: Self.loc("agentXray.entry.rewind.title", "Abandoned Branch"),
                label: Self.loc(
                    "agentXray.entry.rewind.label.entries",
                    "\(abandoned.count) entries"
                ),
                timeMarker: .clock(line.timestamp ?? .distantPast)
            ),
            body: Body(sections: []),
            kind: .rewind(rootUuid: firstUuid),
            subEntries: abandoned
        )
        ctx.root.branchOff(at: parentId, link: link)
    }

    // MARK: - Pending-prompt FIFO

    /// `queue-operation enqueue` arm. Filters task-notification
    /// payloads, appends a `.pending` UserEntry top-level, and pushes
    /// its id+text onto the FIFO for later consumption.
    private func handleQueueEnqueue(
        text: String,
        line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        if text.isEmpty { return }
        if text.hasPrefix("<task-notification>") { return }
        let id = EntryID.fromJSONL(line.stableId)
        let pending = makeUserEntry(
            id: line.stableId,
            timestamp: line.timestamp,
            promptId: nil,
            text: text,
            queuedState: .pending
        )
        ctx.root.append(parent: nil, entry: .user(pending))
        ctx.pendingPromptQueue.append((id, text))
    }

    /// If the FIFO head text equals `text`, pop the head and slice out
    /// the corresponding `.pending` UserEntry from the transcript.
    /// Returns true on consumption, false otherwise (no match → caller
    /// emits its own non-consumed entry).
    private func popPendingPromptQueueIfMatches(
        _ text: String,
        ctx: inout BuildContext
    ) -> Bool {
        guard let head = ctx.pendingPromptQueue.first, head.text == text
        else { return false }
        ctx.pendingPromptQueue.removeFirst()
        ctx.root.slice(from: head.id, length: 1, replacingWith: nil)
        return true
    }

    // MARK: - Special-kind emit

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
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .recap,
                name: Self.loc("agentXray.entry.recap.title", "Recap"),
                body: .text([recapBody]),
                subType: .recap
            ))
        case .prLink:
            guard let prNumber = line.prNumber,
                  let prUrl = line.prUrl,
                  let prRepository = line.prRepository else { return }
            ctx.root.append(parent: nil, entry: .synthesized(SynthesizedEntry(
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
            let reconstructed = args.map { "/\(name) \($0)" } ?? "/\(name)"
            if popPendingPromptQueueIfMatches(reconstructed, ctx: &ctx) {
                let consumed = makeUserEntry(
                    id: id,
                    timestamp: line.timestamp,
                    promptId: line.promptId,
                    text: reconstructed,
                    queuedState: .consumed
                )
                ctx.root.append(parent: nil, entry: .user(consumed))
            } else {
                let title = args.map { "/\(name) \($0)" } ?? "/\(name)"
                ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
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
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .system, name: label,
                body: Body(sections: [.text([b], style: isStderr ? .error : .normal)]),
                subType: .slashCmdOutput(isStderr: isStderr)
            ))
        case .localCommandCaveat:
            return
        case .systemReminder(let b):
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .systemReminder,
                name: Self.loc("agentXray.entry.systemReminder.title", "System reminder"),
                body: .text([b]),
                subType: .systemReminder
            ))
        case .skill(let name, let basePath, let b):
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .skill,
                name: Self.loc("agentXray.entry.skill.title", "Skill: \(name)"),
                title: basePath,
                body: .text([b]),
                subType: .skill(name: name, basePath: basePath)
            ))
        case .contextUsage(let b):
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .contextInfo,
                name: Self.loc("agentXray.entry.contextUsage.title", "Context usage"),
                body: .text([b]),
                subType: .contextUsage
            ))
        case .unknownMeta:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .systemReminder,
                name: Self.loc("agentXray.entry.systemReminder.title", "System reminder"),
                body: .text([trimmed]),
                subType: .systemReminder
            ))
        case .queuedPrompt:
            let text = (line.attachment?.prompt?.firstText() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            _ = popPendingPromptQueueIfMatches(text, ctx: &ctx)
            ctx.root.append(parent: nil, entry: .user(makeUserEntry(
                id: id,
                timestamp: line.timestamp,
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
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
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
            ctx.root.append(parent: nil, entry: Self.makeSystemEntry(
                id: id, ts: ts, icon: .editedTextFile,
                name: Self.loc("agentXray.entry.externalEdit.title", "External edit · \(basename)"),
                body: snippet.map { Body.text([$0]) } ?? .empty,
                subType: .editedTextFile(path: filename)
            ))
        }
    }

    /// Phase + localized phaseName for the three plan-mode special kinds.
    /// Pulled out of `emitSpecial` so the per-kind switch isn't duplicated.
    /// Caller is gated by the `.planModeEntered` / `.planModeExited` /
    /// `.planModeReentered` arms in `emitSpecial`'s switch — passing any
    /// other case is a programmer error.
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
            assertionFailure("planModeMetadata: non-plan-mode kind \(kind)")
            return (.entered, loc("agentXray.entry.planMode.entered", "Plan mode entered"))
        }
    }

    // MARK: - User / System / Compact builders

    private func userRoleLabel(_ state: UserEntry.QueuedState) -> String {
        if state == .pending {
            return Self.loc("agentXray.entry.user.queuedLabel", "Queued")
        }
        return Self.loc("agentXray.entry.user.label", "User")
    }

    /// Construct a `UserEntry` from a per-block ``Section`` array.
    /// Used directly by ``buildUserEntry(from:)`` so user-pasted
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
        let words = wordCount(text)
        let trailing: [TrailingItem] = words > 0
            ? [.wordCount("\(words) words")]
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

    private func buildUserEntry(from line: ClaudeJSONLLine) -> UserEntry? {
        guard line.message?.content != nil else { return nil }
        let sections = UserContentParser.parse(from: line.message?.content)
        return makeUserEntry(
            id: line.stableId,
            timestamp: line.timestamp,
            promptId: line.promptId,
            sections: sections,
            queuedState: .none
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

    // MARK: - Per-line assistant application (post-G6)

    /// Apply one assistant-classified line. Resolves the target
    /// `AgentEntry` via the index walk: if the parent's top-level slot
    /// is `.agent`, fold blocks into it; otherwise this line is the
    /// first content-bearing assistant line of a new turn and creates
    /// a fresh top-level `AgentEntry`. Then per-block dispatch:
    /// text/thinking append `TextSubEntry`; tool_use appends
    /// `ToolEntry`; tool_result mutates an existing `ToolEntry` via
    /// ``ToolResultUpdate``.
    ///
    /// Special case: `system.subtype: turn_duration` JSONL lines
    /// route here through their parent walk too (heterogeneous parent
    /// types: 65.7% assistant, 33.8% system/stop_hook_summary, 0.4%
    /// user/tool_result — all alias-resolve to the right AgentEntry).
    /// Not handled here — handled directly in `dispatch` via the
    /// `applyTurnDuration` helper below, since `system/turn_duration`
    /// lines route to `.skip` from the dispatcher's perspective.
    private func applyAssistantLine(
        _ line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        // Resolve target AgentEntry.
        let agentId = ensureAgentEntry(for: line, ctx: &ctx)
        guard let agentId else { return }

        // Update AgentEntry scalars.
        applyAssistantScalars(line: line, agentId: agentId, ctx: &ctx)

        // Per-block dispatch.
        guard let content = line.message?.content else { return }
        switch content {
        case .text(let str):
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendTextSubEntry(
                    kind: .assistant,
                    text: trimmed,
                    line: line,
                    agentId: agentId,
                    blockIndex: 0,
                    ctx: &ctx
                )
            }
        case .blocks(let blocks):
            for (idx, block) in blocks.enumerated() {
                switch block.type {
                case "text":
                    if let t = block.text {
                        appendTextSubEntry(
                            kind: .assistant,
                            text: t,
                            line: line,
                            agentId: agentId,
                            blockIndex: idx,
                            ctx: &ctx
                        )
                    }
                case "thinking":
                    if let t = block.thinking {
                        appendTextSubEntry(
                            kind: .thinking,
                            text: t,
                            line: line,
                            agentId: agentId,
                            blockIndex: idx,
                            ctx: &ctx
                        )
                    }
                case "tool_use":
                    appendToolUse(
                        block,
                        line: line,
                        agentId: agentId,
                        ctx: &ctx
                    )
                case "tool_result":
                    attachToolResult(
                        block,
                        line: line,
                        ctx: &ctx
                    )
                case "image":
                    // VERIFY-CORPUS-2026-06-07: 0 hits for assistant-emitted
                    // image blocks past this date. Spec-allowed but never
                    // emitted by Claude Code in practice; tool_result and
                    // top-level user pastes carry the real images.
                    logger.warning(
                        "ClaudeTranscriptBuilder: assistant-emitted image block surfaced "
                        + "(spec-only-not-corpus). Skipping."
                    )
                default:
                    break
                }
            }
        }
    }

    /// Find the AgentEntry this assistant line's blocks fold into, or
    /// create a fresh one at top-level if this line opens a new turn.
    /// Returns the AgentEntry's id; nil only if the line carries no
    /// content (rare heartbeat/usage-only assistant lines).
    private func ensureAgentEntry(
        for line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) -> EntryID? {
        guard line.message?.content != nil else { return nil }

        // Walk parent's path → top-level slot. If `.agent`, fold into
        // it; otherwise create a fresh AgentEntry.
        if let parentUuid = line.parentUuid, !parentUuid.isEmpty,
           let parentPath = ctx.root.path(of: .fromJSONL(parentUuid)),
           let topSlot = parentPath.first,
           ctx.root.entries.indices.contains(topSlot),
           case .agent(let existing) = ctx.root.entries[topSlot] {
            return existing.id
        }

        // Fresh AgentEntry — first content-bearing line of a new turn.
        let id = EntryID.fromJSONL(line.stableId)
        let startTime = line.timestamp ?? .distantPast
        let label = Self.loc("agentXray.entry.agent.label.claude", "Claude")
        let agent = AgentEntry(
            id: id,
            header: Header(
                icon: .agent,
                name: label,
                label: nil,
                trailing: [],
                timeMarker: .clock(startTime)
            ),
            body: Body(sections: []),
            usage: .zero,
            stopReason: nil,
            perTurnDurationMs: nil,
            messageCount: nil,
            model: nil,
            endTime: nil,
            subEntries: []
        )
        ctx.root.append(parent: nil, entry: .agent(agent))
        return id
    }

    /// Update AgentEntry scalars from an assistant line: model,
    /// usage delta (additive across all contributing lines),
    /// stopReason, endTime, header label/trailing.
    private func applyAssistantScalars(
        line: ClaudeJSONLLine,
        agentId: EntryID,
        ctx: inout BuildContext
    ) {
        let model = line.message?.model
        let stopReason = line.message?.stopReason
        let lineTs = line.timestamp
        let usageDelta = line.message?.usage

        ctx.root.mutate(id: agentId) { entry in
            guard case .agent(var a) = entry else { return }
            if a.model == nil, let model {
                a.model = model
                a.header = Self.headerSettingLabel(
                    a.header,
                    label: ClaudeModelNameMap.friendlyName(for: model)
                )
            }
            if let stopReason {
                a.stopReason = stopReason
            }
            if let usage = usageDelta {
                a.usage.inputTokens += usage.inputTokens ?? 0
                a.usage.outputTokens += usage.outputTokens ?? 0
                a.usage.cacheReadTokens += usage.cacheReadInputTokens ?? 0
                a.usage.cacheCreationTokens += usage.cacheCreationInputTokens ?? 0
                let total = a.usage.inputTokens + a.usage.outputTokens
                    + a.usage.cacheReadTokens + a.usage.cacheCreationTokens
                a.header = Self.headerSettingTrailing(
                    a.header,
                    trailing: total > 0 ? [.tokenPill(a.usage)] : []
                )
            }
            if let ts = lineTs {
                a.endTime = ts
            }
            entry = .agent(a)
        }
    }

    /// Apply a `system.subtype: turn_duration` line. The dispatcher
    /// invokes this from a special arm — turn_duration routes to
    /// `.render(.system)` would generate a stray SystemEntry, so we
    /// short-circuit it here. Resolution: walk parent's path → top
    /// slot → mutate the AgentEntry there via ``TurnDurationUpdate``.
    private func applyTurnDuration(
        _ line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        guard let parentUuid = line.parentUuid, !parentUuid.isEmpty,
              let parentPath = ctx.root.path(of: .fromJSONL(parentUuid)),
              let topSlot = parentPath.first,
              ctx.root.entries.indices.contains(topSlot),
              case .agent(let agent) = ctx.root.entries[topSlot],
              let durationMs = line.durationMs
        else { return }
        let update = TurnDurationUpdate(
            durationMs: durationMs,
            messageCount: line.messageCount ?? 0
        )
        ctx.root.mutate(id: agent.id) { entry in
            update.apply(&entry)
        }
    }

    /// Reconstruct a `Header` with a new `label`, preserving every
    /// other field. Used when the model is first observed on an
    /// assistant line.
    private static func headerSettingLabel(_ existing: Header, label: String?) -> Header {
        Header(
            icon: existing.icon,
            name: existing.name,
            label: label,
            title: existing.title,
            trailing: existing.trailing,
            timeMarker: existing.timeMarker
        )
    }

    /// Reconstruct a `Header` with new `trailing` items, preserving
    /// every other field. Used to refresh the token-pill trailing item
    /// as usage accumulates.
    private static func headerSettingTrailing(_ existing: Header, trailing: [TrailingItem]) -> Header {
        Header(
            icon: existing.icon,
            name: existing.name,
            label: existing.label,
            title: existing.title,
            trailing: trailing,
            timeMarker: existing.timeMarker
        )
    }

    /// Append a text/thinking sub-entry into the resolved AgentEntry.
    /// Sub-entry id derives from the line's stableId + block index so
    /// chained assistant lines produce unique ids without per-turn
    /// counters. For the modern single-block-per-line case
    /// (99.97% of corpus) the suffix is always `text-0` / `thinking-0`.
    private func appendTextSubEntry(
        kind: TextSubEntry.Kind,
        text: String,
        line: ClaudeJSONLLine,
        agentId: EntryID,
        blockIndex: Int,
        ctx: inout BuildContext
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let kindKey: String
        switch kind {
        case .thinking: kindKey = "thinking-\(blockIndex)"
        case .assistant: kindKey = "text-\(blockIndex)"
        }
        let id = EntryID.derived(parent: line.stableId, kind: kindKey)
        let ts = line.timestamp ?? .distantPast
        let textEntry = Self.makeTextSubEntry(
            kind: kind,
            text: trimmed,
            timestamp: ts,
            id: id,
            parentEntryID: agentId
        )
        ctx.root.append(parent: agentId, entry: .text(textEntry))
    }

    /// Append a `ToolEntry` from a `tool_use` block. The entry's id is
    /// the block's `tool_use_id`; status is `.pending`; timeMarker is
    /// `.clock(startTime)` so the matching `tool_result` mutation can
    /// later replace it with `.duration(ms)`.
    private func appendToolUse(
        _ block: ClaudeContentBlock,
        line: ClaudeJSONLLine,
        agentId: EntryID,
        ctx: inout BuildContext
    ) {
        guard let id = block.id, let name = block.name else { return }
        let teamMemberName = ToolInputParser.teamMemberName(name: name, input: block.input)
        let teamName = ToolInputParser.teamName(name: name, input: block.input)
        let mcpServer = MCPToolNameParser.parse(name).server
        let call = AgentToolCall(
            id: id,
            name: name,
            summary: ToolInputParser.summarize(name: name, input: block.input),
            inputDetail: ToolInputParser.format(block.input),
            subagentType: ToolInputParser.subagentType(name: name, input: block.input),
            teamMemberName: teamMemberName,
            teamName: teamName,
            mcpServer: mcpServer,
            inputFilePath: ToolInputParser.filePath(name: name, input: block.input)
        )
        let toolEntry = Self.makeToolEntry(
            call: call,
            parentId: agentId,
            startTime: line.timestamp
        )
        ctx.root.append(parent: agentId, entry: .tool(toolEntry))
    }

    /// Mutate the matching `ToolEntry` with the result. Pool ordering
    /// guarantees the `tool_use` already created the entry; no
    /// synthetic-fallback path.
    private func attachToolResult(
        _ block: ClaudeContentBlock,
        line: ClaudeJSONLLine,
        ctx: inout BuildContext
    ) {
        guard let id = block.toolUseId else { return }
        let isError = block.isError ?? false
        let resultSections = ToolResultParser.parse(
            block.toolResultContent,
            isError: isError,
            logger: logger
        )
        let toolId = EntryID.fromJSONL(id)
        guard case .tool(let existing) = ctx.root.entry(id: toolId) else {
            // tool_result without a matching tool_use is silently
            // dropped — out-of-order cases are already handled by the
            // pool, so reaching this branch means a genuinely orphan
            // tool_result (e.g., a corrupt JSONL or a manual injection).
            logger.warning(
                "ClaudeTranscriptBuilder: tool_result for tool_use_id \(id) "
                + "with no matching ToolEntry — dropped."
            )
            return
        }
        let durationMs = computeDurationMs(
            startTime: existing.header.timeMarker?.clockDate,
            endTime: line.timestamp
        )
        var update = ToolResultUpdate(
            resultSections: resultSections,
            isError: isError,
            durationMs: durationMs
        )
        // Edit / MultiEdit / Write-update tool results carry a
        // pre-computed unified-diff in `toolUseResult.structuredPatch`.
        // When it's present and non-empty, swap the parser-produced
        // plain-text result section for a single `.code(.diff(...))`
        // section so the row renders the diff with line numbers +
        // per-line backgrounds. Write-create has empty structuredPatch
        // (no pre-edit file to diff against) and falls through.
        if Self.isEditShape(existing.toolName),
           let payload = ClaudeToolUseResult.from(line.toolUseResult),
           let hunks = payload.structuredPatch,
           !hunks.isEmpty {
            let language = LanguagePicker.language(forFilePath: existing.inputFilePath)
            update.resultSections = [.code(.diff(hunks: hunks, language: language))]
        } else if Self.isReadShape(existing.toolName),
                  let path = existing.inputFilePath {
            // Read tool: file content arrives as plain `.text` after
            // `OffloadedOutputParser.promote(_:)` has already swapped
            // any `<persisted-output>` wrapper into `.offloadedOutput`.
            // Each remaining `.text` carries Claude Code's
            // `<padded-line-num>\t<text>` shape (corpus 99.86%) — lift
            // the embedded numbers into `lineNumberStart` so the row
            // gutter shows real file line numbers (with `offset:` /
            // `limit:` honored) and strip them from the rendered text.
            // Status envelopes (e.g. "File does not exist") fall
            // through unchanged — the section stays `.text` and renders
            // as plain prose in a gray box.
            let language = LanguagePicker.language(forFilePath: path)
            update.resultSections = update.resultSections.map { section in
                if case .text(let blocks, _) = section,
                   let parsed = Self.parseReadLineNumbers(blocks.joined(separator: "\n")) {
                    return .code(.plain(
                        text: parsed.text,
                        language: language,
                        lineNumberStart: parsed.lineNumberStart
                    ))
                }
                return section
            }
        }
        ctx.root.mutate(id: toolId) { entry in
            update.apply(&entry)
        }
    }

    /// Tools whose input is rendered via `.code(.diff(...))` from the
    /// result side rather than a plain-text input section. Centralized
    /// so `appendToolUse` (which suppresses the input section) and
    /// `attachToolResult` (which substitutes the diff for the parser
    /// output) agree on the set.
    private static func isEditShape(_ name: String) -> Bool {
        name == "Edit" || name == "MultiEdit" || name == "Write"
    }

    /// Tools whose result is the raw contents of a single file —
    /// rendered via `.code(.plain(...))` with a line-number gutter +
    /// per-language syntax highlighting derived from `inputFilePath`'s
    /// extension. `NotebookRead` is intentionally excluded for now —
    /// its result bundles cell metadata that doesn't render cleanly as
    /// a single fenced code block; revisit after a corpus probe.
    private static func isReadShape(_ name: String) -> Bool {
        name == "Read"
    }

    /// Parse Claude Code's Read tool result format
    /// (`<padded-num>\t<text>` per line) into stripped content + the
    /// first line's number. Returns nil for status envelopes (no
    /// numbered output) — caller leaves the section as `.text` so it
    /// renders as plain prose. Corpus probe 2026-06-10 (9,872 results
    /// / 776 sessions): 99.86% of non-empty lines match `^\s*\d+\t`;
    /// the 0.14% remainder are whole-result envelopes (errors, dedup
    /// markers) that never interleave numbered output.
    private static func parseReadLineNumbers(_ raw: String) -> (text: String, lineNumberStart: Int)? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var stripped: [String] = []
        stripped.reserveCapacity(lines.count)
        var firstNumber: Int?
        for line in lines {
            if line.isEmpty {
                stripped.append("")
                continue
            }
            guard let m = line.firstMatch(of: #/\A\s*(\d+)\t(.*)\z/#),
                  let n = Int(m.output.1) else {
                return nil
            }
            if firstNumber == nil { firstNumber = n }
            stripped.append(String(m.output.2))
        }
        guard let firstNumber else { return nil }
        return (stripped.joined(separator: "\n"), firstNumber)
    }

    /// Compute the duration in milliseconds between a tool's start
    /// (`.clock(...)` time-marker on the appended ToolEntry) and the
    /// matching `tool_result`'s timestamp. Returns nil if either is
    /// missing or the delta is negative (clock skew).
    private func computeDurationMs(startTime: Date?, endTime: Date?) -> Int? {
        guard let startTime, let endTime else { return nil }
        let delta = endTime.timeIntervalSince(startTime)
        return delta >= 0 ? Int(delta * 1000) : nil
    }

    /// Construct a pending `ToolEntry` from a fresh `AgentToolCall`
    /// (parser outputs from `ToolInputParser`). Body is just the input
    /// section(s) — `tool_result` mutation later appends result
    /// sections via ``ToolResultUpdate``. Status is `.pending`;
    /// `header.timeMarker` is `.clock(startTime)` so the matching
    /// `tool_result` mutation can replace it with `.duration(ms)`.
    private static func makeToolEntry(
        call: AgentToolCall,
        parentId: EntryID,
        startTime: Date?
    ) -> ToolEntry {
        // Edit / MultiEdit / Write tools have their input rendered via
        // a `.code(.diff(...))` result section once the structuredPatch
        // lands; an additional input `.text` section above would be
        // redundant (file_path already shows in `Header.title` via the
        // summary step, and old/new strings are about to be re-rendered
        // as the colored diff). Body starts empty for these tools and
        // gains `.code(.diff(...))` when the result mutates via
        // `ToolResultUpdate`.
        let sections: [Section]
        if Self.isEditShape(call.name) {
            sections = []
        } else {
            sections = [.text([call.inputDetail], style: .normal)]
        }
        let parsed = MCPToolNameParser.parse(call.name)
        return ToolEntry(
            id: .fromJSONL(call.id),
            parentEntryID: parentId,
            header: Header(
                icon: .tool(named: call.name),
                name: parsed.display,
                title: call.summary,
                timeMarker: startTime.map { .clock($0) }
            ),
            body: Body(sections: sections),
            status: .pending,
            durationMs: nil,
            subagentType: call.subagentType,
            teamMemberName: call.teamMemberName,
            teamName: call.teamName,
            mcpServer: call.mcpServer,
            inputFilePath: call.inputFilePath
        )
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
