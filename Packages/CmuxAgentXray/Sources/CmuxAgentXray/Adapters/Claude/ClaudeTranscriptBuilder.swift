import Foundation

/// Builds an `[Entry]` transcript from a stream of raw Claude JSONL
/// lines.
///
/// Single-pass per-line dispatch (post-Phase-G). Each line routes
/// through `ClaudeLineDispatcher.route(...)` which decides
/// skip / sidechain / render. The builder mutates a `Transcript`
/// document incrementally — sub-entries flow into a skeleton
/// `AgentEntry` created lazily on the first content-bearing assistant
/// line, scalar fields update via `transcript.mutate(id:)` per
/// contributing line, queued-prompt FIFO is maintained inline,
/// rewinds slice the abandoned tail into a synthesized `branchLink`
/// at the divergence point, and a small pending pool absorbs lines
/// whose JSONL parent hasn't yet been ingested (parallel-tool-call
/// out-of-order).
///
/// The remaining `ClaudeTurnDurationResolver` pre-pass (read once at
/// `transcript()` start) produces a small uuid → duration stamp map
/// applied at turn close; G6 inlines this into the per-line dispatch
/// path.
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
        let turnDurations = ClaudeTurnDurationResolver.resolve(lines: rawLines)

        var ctx = BuildContext(logger: logger)
        ctx.turnDurations = turnDurations.stamps

        for line in rawLines {
            dispatch(line, ctx: &ctx)
        }
        ctx.closePendingTurn()

        // Tail-emit any unconsumed `queue-operation enqueue` mirrors as
        // synthetic `queuedState: .pending` UserEntry rows. Once the
        // queue drains in a later session refresh, the mirror is
        // popped (in `observeRawLine`) and the matching real
        // attachment.queued_command emits its own non-pending UserEntry
        // — the pending pseudo-entry drops out of the next transcript.
        // The `queue-pending:<ts>:<hash>` id format matches the legacy
        // `ClaudeQueuedPromptResolver` output so downstream `EntryID`
        // equality holds across the migration.
        for mirror in ctx.pendingPromptMirrors {
            ctx.appendEntry(.user(makeUserEntry(
                id: mirror.id,
                timestamp: mirror.timestamp,
                promptId: nil,
                text: mirror.text,
                queuedState: .pending
            )))
        }

        return ctx.root.entries
    }

    // MARK: - G5 inline FIFO queued-prompt

    /// Mirror of one outstanding `queue-operation enqueue` line. Held
    /// in `BuildContext.pendingPromptMirrors` until paired with a
    /// consuming user line (slash-command or
    /// `attachment.queued_command`). Carries a stable id matching the
    /// pre-G5 `ClaudeQueuedPromptResolver` format
    /// (`queue-pending:<unix-ts>:<text-hash>`) so downstream
    /// `EntryID` equality holds across the migration.
    fileprivate struct PendingPromptMirror: Equatable {
        let id: String
        let text: String
        let timestamp: Date
    }

    /// Pre-routing hook invoked as the first statement of `dispatch`.
    /// Three jobs:
    ///   1. Push every non-task-notification `queue-operation enqueue`
    ///      onto the FIFO (will be tail-emitted as a pending UserEntry
    ///      if not consumed by end-of-stream).
    ///   2. When a user-typed slash-command line arrives whose
    ///      reconstructed `/cmd args` text matches a pending mirror,
    ///      pop the matching mirror and mark the line's stableId as
    ///      consumed (drives `queuedState: .consumed` at emit time).
    ///   3. When an `attachment.queued_command` arrives whose prompt
    ///      text matches a pending mirror, pop the mirror (the
    ///      attachment surfaces its own UserEntry via
    ///      `emitSpecial(.queuedPrompt)`).
    /// Replaces the pre-G5 `ClaudeQueuedPromptResolver` two-pass.
    private func observeRawLine(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        if line.type == "queue-operation", line.operation == "enqueue" {
            let text = (line.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            // task-notification entries ride the queue but never
            // surface as user prompts — drop them at intake.
            if text.hasPrefix("<task-notification>") { return }
            let ts = line.timestamp ?? .distantPast
            let id = "queue-pending:\(ts.timeIntervalSince1970):\(text.hashValue)"
            ctx.pendingPromptMirrors.append(
                PendingPromptMirror(id: id, text: text, timestamp: ts)
            )
            return
        }
        if line.type == "user", let slashText = line.consumedSlashCommandText {
            if let idx = ctx.pendingPromptMirrors.firstIndex(where: { $0.text == slashText }) {
                ctx.pendingPromptMirrors.remove(at: idx)
                ctx.consumedSlashCmdUuids.insert(line.stableId)
            }
            return
        }
        if line.type == "attachment", line.attachment?.type == "queued_command" {
            let text = (line.attachment?.prompt?.firstText() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            if let idx = ctx.pendingPromptMirrors.firstIndex(where: { $0.text == text }) {
                ctx.pendingPromptMirrors.remove(at: idx)
            }
            return
        }
    }

    // MARK: - Top-level dispatch

    private func dispatch(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        dispatchOneLine(line, ctx: &ctx)
        drainPool(ctx: &ctx)
    }

    /// One line's dispatch work, NOT including pool drain. Pool drain
    /// is invoked once after the wrapping `dispatch(_:ctx:)` because
    /// any successful append registers new ids that may unblock
    /// previously-pooled lines.
    private func dispatchOneLine(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        // G5 inline FIFO queued-prompt hook — must run as the first
        // statement, before any early-return, to capture
        // `queue-operation enqueue` lines (which `CommonLineDispatcher`
        // routes to `.skip` further down) and to consume FIFO entries
        // when a matching slash-command user line or
        // `attachment.queued_command` arrives.
        observeRawLine(line, ctx: &ctx)

        // last-prompt markers: 97% of them are session-resume /
        // permission-checkpoint hints (Audit 2 from the streamed-
        // cuddling-stream plan, 5,849 markers / 156 actually rewind-
        // adjacent). Drop entirely — rewind detection is structural
        // (parentUuid → earlier user-prompt child) and doesn't
        // consult markers.
        if line.isLastPromptMarker { return }

        if line.type == "system", line.subtype == "turn_duration" {
            return
        }

        // Parent-availability check. Lines whose JSONL parent isn't
        // yet reachable — typically parallel-tool-call `tool_result`
        // user lines arriving in write-order rather than topological
        // order — pool until the parent arrives. drainPool retries on
        // every successful append. Reachable = parent is in the
        // transcript OR has already been dispatched (chained
        // assistant lines reference their predecessor by uuid, but
        // only the first assistant line's uuid lands in the
        // transcript as the skeleton's id).
        if let parentJSONL = line.parentUuid,
           !parentJSONL.isEmpty,
           ctx.root.entry(id: .fromJSONL(parentJSONL)) == nil,
           !ctx.dispatchedUuids.contains(parentJSONL) {
            ctx.pendingPool.append(line)
            return
        }

        let routing = ClaudeLineDispatcher.route(line, logger: logger)

        // Mark the line as dispatched BEFORE routing so any cascading
        // append/mutate paths see it as reachable for downstream
        // children's parent checks.
        if let uuid = line.uuid {
            ctx.dispatchedUuids.insert(uuid)
        }

        switch routing {
        case .skip:
            return
        case .sidechainMain:
            ctx.collectSidechainLine(line)
            return
        case .render(let kind):
            switch kind {
            case .compact:
                ctx.closePendingTurn()
                ctx.appendEntry(.compact(buildCompactEntry(from: line)))
                recordUserPromptChild(line: line, entryId: .fromJSONL(line.stableId), ctx: &ctx)
            case .user:
                let cat = classify(line)
                switch cat {
                case .user:
                    detectAndApplyRewindIfTopLevelUser(line, ctx: &ctx)
                    ctx.closePendingTurn()
                    if let entry = buildUserEntry(from: line, ctx: ctx) {
                        ctx.appendEntry(.user(entry))
                        recordUserPromptChild(line: line, entryId: entry.id, ctx: &ctx)
                    }
                case .system:
                    ctx.closePendingTurn()
                    if let entry = buildSystemEntry(from: line) {
                        ctx.appendEntry(.system(entry))
                    }
                case .agent:
                    applyAssistantLine(line, ctx: &ctx)
                case .hardNoise:
                    return
                }
            case .system:
                ctx.closePendingTurn()
                if let entry = buildSystemEntry(from: line) {
                    ctx.appendEntry(.system(entry))
                }
            case .agent:
                applyAssistantLine(line, ctx: &ctx)
            }
        case .renderSpecial(let kind):
            ctx.closePendingTurn()
            emitSpecial(line, kind: kind, ctx: &ctx)
        }
    }

    /// Drain pooled lines whose JSONL parent has become reachable.
    /// Each iteration removes all currently-unblockable entries and
    /// dispatches them; the loop continues until no further progress
    /// is possible (terminating bound = pool size).
    private func drainPool(ctx: inout BuildContext) {
        var changed = true
        while changed {
            changed = false
            var stillPending: [ClaudeJSONLLine] = []
            var unblocked: [ClaudeJSONLLine] = []
            for pooled in ctx.pendingPool {
                if let parentJSONL = pooled.parentUuid,
                   !parentJSONL.isEmpty,
                   ctx.root.entry(id: .fromJSONL(parentJSONL)) == nil,
                   !ctx.dispatchedUuids.contains(parentJSONL) {
                    stillPending.append(pooled)
                } else {
                    unblocked.append(pooled)
                }
            }
            if !unblocked.isEmpty {
                ctx.pendingPool = stillPending
                for pooled in unblocked {
                    dispatchOneLine(pooled, ctx: &ctx)
                }
                changed = true
            }
        }
    }

    /// Record `entryId` as a user-prompt child of `line.parentUuid`
    /// (resolved to its EntryID) so a future rewind whose `parentUuid`
    /// matches the same parent can detect that an earlier user prompt
    /// already chains off this point.
    private func recordUserPromptChild(line: ClaudeJSONLLine, entryId: EntryID, ctx: inout BuildContext) {
        guard let parentJSONL = line.parentUuid, !parentJSONL.isEmpty else { return }
        let parentId = EntryID.fromJSONL(parentJSONL)
        ctx.userPromptChildrenByParent[parentId, default: []].append(entryId)
    }

    /// Inline rewind detector. Fires only on top-level user-typed
    /// prompts. Detection: the new prompt's `parentUuid` resolves to
    /// an EntryID `parentId`; if `userPromptChildrenByParent[parentId]`
    /// already contains an earlier user-prompt child whose id ≠ this
    /// line's id, the user has rewound — slice the abandoned tail
    /// past `parentId` into a synthesized `branchLink`.
    private func detectAndApplyRewindIfTopLevelUser(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        guard let parentJSONL = line.parentUuid, !parentJSONL.isEmpty else { return }
        let parentId = EntryID.fromJSONL(parentJSONL)
        // Top-level rewind only — corpus 85/85 + zero non-tail call
        // sites confirms this. Defensive: if the parent isn't at
        // top level, skip rewind detection.
        guard let parentPath = ctx.root.path(of: parentId), parentPath.count == 1 else { return }
        let earlier = ctx.userPromptChildrenByParent[parentId, default: []]
        let thisId = EntryID.fromJSONL(line.stableId)
        guard !earlier.isEmpty, !earlier.contains(thisId) else { return }
        // Slice the abandoned tail past parentId's slot into a
        // branchLink. The first abandoned entry's id keys the link
        // (post-G1.5 / G1.6 contract). Use it for both the
        // branchRootUuid and the link's derived id so multi-rewind
        // produces distinct ids.
        let parentSlot = parentPath[0]
        let start = parentSlot + 1
        guard start < ctx.root.entries.count else { return }
        let abandoned = Array(ctx.root.entries[start...])
        guard let firstAbandoned = abandoned.first else { return }
        ctx.rewindIndex += 1
        let preview = firstAbandonedPromptPreview(in: abandoned)
        let totalRewinds = ctx.rewindIndex
        let title = Self.loc(
            "agentXray.entry.branchLink.title",
            "Rewind \(ctx.rewindIndex) of \(totalRewinds)"
        )
        let subtitle = Self.loc(
            "agentXray.entry.branchLink.subtitle",
            "\(abandoned.count) entries · \(preview ?? Self.loc("agentXray.entry.branchLink.noPrompt", "(no prompt)"))"
        )
        let firstUuid = firstAbandoned.id.stableString
        let link = SynthesizedEntry(
            id: .derived(parent: firstUuid, kind: "branchLink"),
            header: Header(
                icon: .branchLink,
                name: title,
                title: subtitle,
                timeMarker: .clock(line.timestamp ?? .distantPast)
            ),
            body: Body(sections: []),
            kind: .branchLink(
                branchRootUuid: firstUuid,
                rewindIndex: ctx.rewindIndex,
                totalRewinds: totalRewinds,
                entryCount: abandoned.count,
                firstPromptPreview: preview
            ),
            subEntries: abandoned
        )
        ctx.root.branchOff(at: parentId, link: link)
    }

    /// First non-empty user-prompt preview text inside an abandoned
    /// subtree.
    private func firstAbandonedPromptPreview(in entries: [Entry]) -> String? {
        for entry in entries {
            if case .user(let u) = entry, let title = u.header.title, !title.isEmpty {
                return title
            }
            if case .synthesized(let s) = entry, !s.subEntries.isEmpty {
                if let preview = firstAbandonedPromptPreview(in: s.subEntries) {
                    return preview
                }
            }
        }
        return nil
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
            ctx.appendEntry(Self.makeSystemEntry(
                id: id, ts: ts, icon: .recap,
                name: Self.loc("agentXray.entry.recap.title", "Recap"),
                body: .text([recapBody]),
                subType: .recap
            ))
        case .prLink:
            guard let prNumber = line.prNumber,
                  let prUrl = line.prUrl,
                  let prRepository = line.prRepository else { return }
            ctx.appendEntry(.synthesized(SynthesizedEntry(
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
            if ctx.consumedSlashCmdUuids.contains(line.stableId) {
                let text = line.consumedSlashCommandText ?? body
                ctx.appendEntry(.user(makeUserEntry(
                    id: id,
                    timestamp: ts,
                    promptId: line.promptId,
                    text: text,
                    queuedState: .consumed
                )))
            } else {
                let title = args.map { "/\(name) \($0)" } ?? "/\(name)"
                ctx.appendEntry(Self.makeSystemEntry(
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
            ctx.appendEntry(Self.makeSystemEntry(
                id: id, ts: ts, icon: .system, name: label,
                body: Body(sections: [.text([b], style: isStderr ? .error : .normal)]),
                subType: .slashCmdOutput(isStderr: isStderr)
            ))
        case .localCommandCaveat:
            return
        case .systemReminder(let b):
            ctx.appendEntry(Self.makeSystemEntry(
                id: id, ts: ts, icon: .systemReminder,
                name: Self.loc("agentXray.entry.systemReminder.title", "System reminder"),
                body: .text([b]),
                subType: .systemReminder
            ))
        case .skill(let name, let basePath, let b):
            ctx.appendEntry(Self.makeSystemEntry(
                id: id, ts: ts, icon: .skill,
                name: Self.loc("agentXray.entry.skill.title", "Skill: \(name)"),
                title: basePath,
                body: .text([b]),
                subType: .skill(name: name, basePath: basePath)
            ))
        case .contextUsage(let b):
            ctx.appendEntry(Self.makeSystemEntry(
                id: id, ts: ts, icon: .contextInfo,
                name: Self.loc("agentXray.entry.contextUsage.title", "Context usage"),
                body: .text([b]),
                subType: .contextUsage
            ))
        case .unknownMeta:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            ctx.appendEntry(Self.makeSystemEntry(
                id: id, ts: ts, icon: .systemReminder,
                name: Self.loc("agentXray.entry.systemReminder.title", "System reminder"),
                body: .text([trimmed]),
                subType: .systemReminder
            ))
        case .queuedPrompt:
            let text = (line.attachment?.prompt?.firstText() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            ctx.appendEntry(.user(makeUserEntry(
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
            ctx.appendEntry(Self.makeSystemEntry(
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
            ctx.appendEntry(Self.makeSystemEntry(
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
        let wasQueued = ctx.consumedSlashCmdUuids.contains(line.stableId)
        if isSlash, let slash = line.consumedSlashCommandText {
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

    // MARK: - Build context (per-snapshot mutable state)

    fileprivate struct BuildContext {
        /// Forwarded from the parent `ClaudeTranscriptBuilder` so
        /// recursive sub-builders (sidechain transcripts) carry the
        /// same logger and don't silently drop the spec-only-not-corpus
        /// warnings emitted by `buildToolResultSections`.
        let logger: any AgentXrayLogger
        /// Phase G transcript model. Source of truth — `transcript()`
        /// returns `root.entries`.
        var root = Transcript()

        // MARK: - Per-turn skeleton tracking (post-G3)
        //
        // The hot path no longer accumulates in a `PendingTurn` that
        // flushes into a fresh AgentEntry. Instead, the first
        // content-bearing assistant line of a turn creates a skeleton
        // AgentEntry directly in `root` (via `ensureSkeleton`), and
        // subsequent lines incrementally update its scalars via
        // `transcript.mutate(id: skeletonId)` and append sub-entries
        // via `transcript.append(parent: skeletonId, ...)`.

        /// Id of the skeleton AgentEntry currently being built, if any.
        var pendingAgentSkeletonId: EntryID?
        /// Timestamp of the first contributing line of the current turn
        /// — used as the skeleton's clock marker and as the start
        /// reference for tool durationMs computation.
        var pendingTurnStartTime: Date?
        /// Latest contributing-line timestamp seen for this turn.
        /// Becomes the skeleton's `endTime`.
        var pendingTurnLastTimestamp: Date?
        /// uuid of the latest contributing line for this turn —
        /// consumed by `closePendingTurn` to look up the turn-duration
        /// stamp keyed by lastMessageUuid.
        var pendingTurnLastMessageUuid: String?
        /// De-dup set for usage aggregation. Each assistant message id
        /// (or fallback uuid) is added once; usage from the same id is
        /// not double-counted.
        var pendingTurnUsageMessageIds: Set<String> = []
        /// Per-turn counter for derived `thinking-N` ids.
        var turnThinkingCounter: Int = 0
        /// Per-turn counter for derived `assistantText-N` ids.
        var turnAssistantTextCounter: Int = 0
        /// `tool_use_id` → start timestamp. Populated when a tool_use
        /// is appended; consumed by `attachToolResult` to compute
        /// `durationMs`.
        var toolStartedAtById: [String: Date] = [:]
        /// `tool_use_id` → mutable AgentToolCall accumulator. Lets
        /// `attachToolResult` re-render the tool's body without
        /// duplicating input sections when a result arrives. Cleared
        /// at turn close.
        var toolCallById: [String: AgentToolCall] = [:]

        // MARK: - Pre-G6 carry-forwards (deleted in G6's sweep)

        var turnDurations: [String: TurnDurationStamp] = [:]
        /// Sidechain pipeline scratchpad — collected but never
        /// surfaced post-G1.5-fix. G6 sweeps the entire pipeline.
        var sidechainLinesByParent: [String: [ClaudeJSONLLine]] = [:]

        // MARK: - Inline FIFO queued-prompt state (post-G5)

        /// File-order queue of `queue-operation enqueue` lines that
        /// have not yet been paired with a consuming user line
        /// (slash-command or attachment.queued_command).
        var pendingPromptMirrors: [PendingPromptMirror] = []
        /// `stableId` of user-typed slash-command lines whose text
        /// matched a prior enqueue. Replaces the pre-G5
        /// `queuedSlashCommandUuids` from `ClaudeQueuedPromptResolver`.
        var consumedSlashCmdUuids: Set<String> = []

        // MARK: - G4 per-line rewind detection state

        /// JSONL-parent → ordered list of user-prompt entry ids whose
        /// `parentUuid` resolves to that node. Populated by `dispatch`
        /// every time it routes a user-typed prompt. Read by the
        /// inline rewind detector: a new user prompt whose
        /// `parentUuid` already has an earlier entry in this map is
        /// reusing a node — i.e., the user has rewound and re-spoken.
        var userPromptChildrenByParent: [EntryID: [EntryID]] = [:]
        /// Lines whose `parentUuid` isn't yet reachable at dispatch
        /// time. Reachable means either (a) the parent's EntryID is
        /// in `root` already, or (b) we've at least *seen* that uuid
        /// in `dispatchedUuids` — covering assistant lines whose own
        /// uuid never lands in the transcript directly (only their
        /// content-block ids do, e.g. tool_use ids). Drained
        /// recursively after every successful append.
        var pendingPool: [ClaudeJSONLLine] = []
        /// Every JSONL line uuid we've successfully dispatched so far,
        /// regardless of whether it became an addressable entry. Used
        /// to gate the pending-pool parent-availability check —
        /// chained assistant lines reference their predecessor by
        /// uuid, but only the first line's uuid is registered in the
        /// transcript (as the skeleton's id).
        var dispatchedUuids: Set<String> = []
        /// 1-based per-session counter for branch-link "Rewind N"
        /// labels. Increments each time `detectAndApplyRewind` fires.
        var rewindIndex: Int = 0

        /// Append a top-level entry. Wraps
        /// ``Transcript/append(parent:entry:)`` with `parent: nil`.
        mutating func appendEntry(_ entry: Entry) {
            root.append(parent: nil, entry: entry)
        }

        /// Close the in-flight agent turn. The skeleton AgentEntry
        /// already lives in `root.entries` with all aggregates baked
        /// in from incremental mutations during the turn — this just
        /// applies the turn-duration stamp (if known) and clears the
        /// per-turn tracking state.
        mutating func closePendingTurn() {
            guard let skeletonId = pendingAgentSkeletonId else { return }
            if let lastUuid = pendingTurnLastMessageUuid,
               let stamp = turnDurations[lastUuid] {
                root.mutate(id: skeletonId) { entry in
                    if case .agent(var a) = entry {
                        a.perTurnDurationMs = stamp.durationMs
                        a.messageCount = stamp.messageCount
                        entry = .agent(a)
                    }
                }
            }
            pendingAgentSkeletonId = nil
            pendingTurnStartTime = nil
            pendingTurnLastTimestamp = nil
            pendingTurnLastMessageUuid = nil
            pendingTurnUsageMessageIds.removeAll()
            turnThinkingCounter = 0
            turnAssistantTextCounter = 0
            toolStartedAtById.removeAll()
            toolCallById.removeAll()
        }

        mutating func collectSidechainLine(_ line: ClaudeJSONLLine) {
            guard let parent = line.parentToolUseID else { return }
            sidechainLinesByParent[parent, default: []].append(line)
        }
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

    // MARK: - Per-line assistant application (post-G3)

    /// Lazily create the skeleton AgentEntry for the current turn. The
    /// caller invokes this on the first content-bearing assistant line
    /// of the turn. Subsequent lines find the skeleton already in
    /// place and update its scalars / append sub-entries directly.
    private func ensureSkeleton(ctx: inout BuildContext, line: ClaudeJSONLLine) {
        if ctx.pendingAgentSkeletonId != nil { return }
        let id = EntryID.fromJSONL(line.stableId)
        let startTime = line.timestamp ?? .distantPast
        let label = Self.loc("agentXray.entry.agent.label.claude", "Claude")
        let skeleton = AgentEntry(
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
        ctx.appendEntry(.agent(skeleton))
        ctx.pendingAgentSkeletonId = id
        ctx.pendingTurnStartTime = startTime
    }

    /// Apply one assistant-classified line to the in-flight turn. If
    /// the line carries content, the skeleton is created (if not yet)
    /// and its scalars + sub-entries are mutated incrementally.
    /// Heartbeat / usage-only lines that arrive while a skeleton
    /// exists update the skeleton's tracking state but do not append
    /// any sub-entry.
    ///
    /// Replaces the pre-G3 `mergeIntoPendingTurn(_:ctx:)` whose
    /// `PendingTurn.subEntries` accumulator + `flushPendingTurn`
    /// projection has been collapsed: sub-entries flow directly into
    /// `transcript`, and the skeleton itself is the source of truth
    /// from creation onward.
    private func applyAssistantLine(_ line: ClaudeJSONLLine, ctx: inout BuildContext) {
        if line.message?.content != nil {
            ensureSkeleton(ctx: &ctx, line: line)
        }
        guard let skeletonId = ctx.pendingAgentSkeletonId else { return }
        if let ts = line.timestamp {
            ctx.pendingTurnLastTimestamp = ts
        }
        if let uuid = line.uuid {
            ctx.pendingTurnLastMessageUuid = uuid
        }

        // Capture incremental update inputs locally — Swift closures
        // can't capture inout `ctx` for mutation, so we precompute
        // the usage-dedup decision before entering the mutate closure.
        let model = line.message?.model
        let stopReason = line.message?.stopReason
        let lineTs = line.timestamp
        let usageDelta: ClaudeUsage?
        if let usage = line.message?.usage {
            let identity = line.message?.id ?? line.uuid ?? line.stableId
            if ctx.pendingTurnUsageMessageIds.insert(identity).inserted {
                usageDelta = usage
            } else {
                usageDelta = nil
            }
        } else {
            usageDelta = nil
        }

        ctx.root.mutate(id: skeletonId) { entry in
            if case .agent(var a) = entry {
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

        guard let content = line.message?.content else { return }
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

    /// Reconstruct a `Header` with a new `label`, preserving every
    /// other field. Used by `applyAssistantLine` to refresh the
    /// skeleton's header when the model is first observed.
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
    /// every other field. Used to refresh the skeleton's token-pill
    /// trailing item as usage accumulates.
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

    /// Render an `AgentToolCall` accumulator into a `ToolEntry` ready
    /// to drop into the skeleton's `subEntries`. Used by
    /// `appendToolUse` (initial render with `status: .pending`,
    /// `durationMs: nil`) and `attachToolResult` (re-render with the
    /// observed result + duration).
    private static func makeToolEntryEntry(
        call: AgentToolCall,
        parentId: EntryID,
        durationMs: Int?,
        status: ToolEntry.Status
    ) -> ToolEntry {
        var sections: [Section]
        if let diffSections = call.diffSections {
            sections = diffSections
        } else {
            sections = [.text([call.inputDetail], style: .normal)]
        }
        if let resultSections = call.result {
            sections.append(contentsOf: resultSections)
        }
        let parsed = MCPToolNameParser.parse(call.name)
        return ToolEntry(
            id: .fromJSONL(call.id),
            parentEntryID: parentId,
            header: Header(
                icon: .tool(named: call.name),
                name: parsed.display,
                title: call.summary,
                timeMarker: durationMs.map { .duration($0) }
            ),
            body: Body(sections: sections),
            status: status,
            durationMs: durationMs,
            subagentType: call.subagentType,
            teamMemberName: call.teamMemberName,
            teamName: call.teamName,
            mcpServer: call.mcpServer,
            inputFilePath: call.inputFilePath
        )
    }

    /// Append one text sub-entry directly under the current skeleton.
    /// Both thinking and final assistant text blocks route here; the
    /// `kind` discriminator drives the per-kind counter for derived
    /// ids and the per-kind icon/style for the rendered TextSubEntry.
    private func appendTextEvent(
        kind: TextSubEntry.Kind,
        _ text: String,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let skeletonId = ctx.pendingAgentSkeletonId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let suffix: String
        switch kind {
        case .thinking:
            let idx = ctx.turnThinkingCounter
            ctx.turnThinkingCounter += 1
            suffix = "thinking-\(idx)"
        case .assistant:
            let idx = ctx.turnAssistantTextCounter
            ctx.turnAssistantTextCounter += 1
            suffix = "assistantText-\(idx)"
        }
        let id = EntryID.derived(parent: skeletonId.stableString, kind: suffix)
        // Fallback timestamp matches the prior flush-time projection:
        // assistant text without its own ts uses the latest known turn
        // timestamp; thinking falls back to the turn's start time.
        let fallbackTs: Date
        switch kind {
        case .assistant:
            fallbackTs = timestamp
                ?? ctx.pendingTurnLastTimestamp
                ?? ctx.pendingTurnStartTime
                ?? .distantPast
        case .thinking:
            fallbackTs = timestamp
                ?? ctx.pendingTurnStartTime
                ?? .distantPast
        }
        let textEntry = Self.makeTextSubEntry(
            kind: kind,
            text: trimmed,
            timestamp: fallbackTs,
            id: id,
            parentEntryID: skeletonId
        )
        ctx.root.append(parent: skeletonId, entry: .text(textEntry))
    }

    private func appendToolUse(
        _ block: ClaudeContentBlock,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let id = block.id, let name = block.name else { return }
        guard let skeletonId = ctx.pendingAgentSkeletonId else { return }
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
        let toolId = EntryID.fromJSONL(id)
        let toolEntry = Self.makeToolEntryEntry(
            call: call, parentId: skeletonId, durationMs: nil, status: .pending
        )
        // Cross-turn id-reuse safeguard: only mutate in place if the
        // existing slot is parented to the *current* skeleton. A tool
        // id legitimately recurring across turns (the prior turn's
        // synthetic-fallback id resurfacing in this turn's tool_use)
        // appends fresh under the current skeleton instead.
        if case .tool(let existing) = ctx.root.entry(id: toolId),
           existing.parentEntryID == skeletonId {
            ctx.root.mutate(id: toolId) { entry in
                entry = .tool(toolEntry)
            }
        } else {
            ctx.root.append(parent: skeletonId, entry: .tool(toolEntry))
        }
        ctx.toolStartedAtById[id] = timestamp
        ctx.toolCallById[id] = call
    }

    private func attachToolResult(
        _ block: ClaudeContentBlock,
        timestamp: Date?,
        ctx: inout BuildContext
    ) {
        guard let id = block.toolUseId,
              let skeletonId = ctx.pendingAgentSkeletonId else { return }
        let isError = block.isError ?? false
        let resultSections = ToolResultParser.parse(
            block.toolResultContent,
            isError: isError,
            logger: logger
        )
        let toolId = EntryID.fromJSONL(id)

        // Existing-tool path (parent-scoped to the current skeleton).
        if case .tool(let existing) = ctx.root.entry(id: toolId),
           existing.parentEntryID == skeletonId,
           var call = ctx.toolCallById[id] {
            let startedAt = ctx.toolStartedAtById[id]
            let durationMs = startedAt.flatMap { started -> Int? in
                guard let timestamp else { return nil }
                let delta = timestamp.timeIntervalSince(started)
                return delta >= 0 ? Int(delta * 1000) : nil
            }
            call = call.withResult(resultSections, isError: isError, durationMs: durationMs)
            ctx.toolCallById[id] = call
            let status: ToolEntry.Status = isError ? .error : .ok
            let toolEntry = Self.makeToolEntryEntry(
                call: call, parentId: skeletonId,
                durationMs: durationMs, status: status
            )
            ctx.root.mutate(id: toolId) { entry in
                entry = .tool(toolEntry)
            }
            return
        }

        // Synthetic — tool_result arrived without a prior tool_use in
        // the current turn (or the matching slot is from a prior
        // turn). Append under the current skeleton with the tool_use
        // id so a later real tool_use mutates the same slot.
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
        let status: ToolEntry.Status = isError ? .error : .ok
        let toolEntry = Self.makeToolEntryEntry(
            call: synthetic, parentId: skeletonId,
            durationMs: nil, status: status
        )
        ctx.root.append(parent: skeletonId, entry: .tool(toolEntry))
        ctx.toolCallById[id] = synthetic
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
