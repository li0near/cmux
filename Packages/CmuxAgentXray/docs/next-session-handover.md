# AgentX-ray — pending work handover (2026-06-08, mid-Phase-G)

## Current state (mid-Phase-G implementation, 4 of 8 sub-commits landed)

Phase G is **partially landed**. Four sub-commits are on `agentxray`,
each tagged in the title with its sub-commit number:

| Commit | Sub-commit | Topic | Test count |
|---|---|---|---|
| `24a20bf94` | G0/8 | Inline skill discriminator (single-line tag-order) | 143/19 |
| `c9e734eab` | G1/8 | `TranscriptRoot` infrastructure | 155/20 |
| `b36effc9c` | G2a/8 | Dual-write `TranscriptRoot` alongside `ctx.entries` | 155/20 |
| `4bec941d8` | G2b/8 | Switch `transcript()` to `root.subEntries` | 155/20 |

The plan that produced these is at
`/Users/I505728/.claude/plans/streamed-cuddling-stream.md` and stays
authoritative for the rest of Phase G. Read it before continuing.

**G3 attempt was reverted in this session.** Collapsing `PendingTurn`
(its `subEntries: [PendingSubEntry]` accumulator + `toolIndexByID`
lookup) requires rewriting `mergeIntoPendingTurn`, `appendTextEvent`,
`appendToolUse`, `attachToolResult`, and `flushPendingTurn`
together. Unlike G2a's top-level dual-write, there is no equivalent
safety net for sub-entries — `TranscriptRoot.index` doesn't track
sub-entries until the parent `AgentEntry` is appended (currently at
flush time). Doing the rewrite + verifying behaviour across 155 tests
in one push without intermediate commits is high-risk for subtle
regressions in tool-result attachment, duplicate-tool_use idempotence,
or sidechain attachment ordering. **A safer G3 approach is sketched
at the bottom of this section.**

**Sidechain corpus survey for the future G3** (run during 19v):
- 710 sessions, 36,113 sidechain lines.
- **0 uuid collisions** between sidechain and parent-session lines —
  Assumption 1 (unified `EntryID` index is collision-free) holds.
- 204 orphan `parentToolUseID` references in 16 sessions, **all in
  subagent files where the parent `messages.jsonl` is missing**. Not
  data corruption — just incomplete corpus when parent transcripts
  are archived/deleted while subagent files remain. Future G3 must
  handle the orphan case gracefully (skip-or-warn, falling through
  to the existing synthetic-tool fallback in `attachToolResult`).

**Remaining sub-commits** (deferred to a follow-up session):

- **G3** — collapse `PendingTurn` + drop recursive sidechain rebuild.
- **G4** — inline branch detection at `last-prompt` arrival; delete
  `ClaudeBranchResolver` (multi-pass + fixpoint loop). Note the
  resolver also produces the `activeUUIDs` set used for branch-
  gating in `ClaudeLineDispatcher.branchGated`; replacement must
  preserve that path.
- **G5** — inline FIFO queued-prompt; delete `ClaudeQueuedPromptResolver`.
- **G6** — cleanup, doc updates, retire this handover doc.

### Suggested safer-G3 approach for the next session

Add a sub-entry dual-write phase analogous to G2a/G2b before
collapsing `PendingTurn`:

1. **G3a (sub-entry dual-write infrastructure)** — `BuildContext`
   gains a stored `var pendingAgentEntryId: EntryID?` and a helper
   `appendSubEntry(_:)` that writes to BOTH the legacy
   `pendingTurn!.subEntries` accumulator AND `root.appendSubEntry`.
   First requires creating the `AgentEntry` skeleton in `root` at
   the start of a turn (when the first assistant block arrives) so
   `root.appendSubEntry(parentAgentId:)` has a valid parent. The
   skeleton agent's final fields (`usage`, `model`, `endTime`,
   `perTurnDurationMs`, `messageCount`, `stopReason`) get baked in
   at flush via `root.mutate(id: pendingAgentEntryId)`. Add a
   debug-only assert at flush time: `pending.subEntries.count`
   matches the count of agent's sub-entries via the index, and
   per-position id equality holds.
2. **G3b (flip)** — Promote the dual-write target to source of
   truth: drop `PendingTurn.subEntries` and `toolIndexByID`. Tool
   result attachment goes through `root.mutateSubEntry`. Sidechain
   stays as-is (recursive `buildSidechainEntries`).
3. **G3c (drop recursive sidechain)** — Optional follow-up. Requires
   extending `TranscriptRoot.EntrySlot` with a third variant for
   "inside a `ToolEntry.body.sections[i].subentries[j]`" so
   sidechain entries get index lookups too. With the sidechain
   corpus survey clear (0 uuid collisions), this is safe.

The carry-forward sections below remain — original Phase G design
(§A through §D) and older deferrals — for context.

---

# Original Phase G design (kept for reference; consult the plan file
# for current sequencing)

This doc replaces the prior 2026-06-08 post-Phase-F handover (which
queued small follow-ups: transcript renderer FU3, screenshot
discrimination, pane placement, audit S3). Those items are still
deferred-but-low-priority — they're listed in the **carry-forward**
section at the bottom.

The headline below is **Phase G** — a substantial architectural
redesign of the transcript builder pipeline. Phase G replaces the
current "rebuild from scratch on every ingest batch" model with
**event-driven incremental in-place updates**. It collapses several
ad-hoc accumulators (PendingTurn, abandoned-branch pre-pass, queued-
prompt resolver tail-emit) into one uniform "events apply to a tree
of entries indexed by id" model. Performance scales linearly with
arrival rate instead of quadratically with session lifetime.

Phase G is independent of and successor to all phases A through F.
Read this doc end-to-end before planning.

---

## Verify baseline first (mandatory)

Code has been actively modified during the conversation that produced
this doc. **DO NOT trust file paths, line numbers, or symbol names in
this doc without verifying against current source.** Specifically:

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline
swift test --package-path Packages/CmuxAgentXray
```

Then re-read the following files end-to-end before drafting the plan,
because each was actively edited late in the design discussion:

- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/ClaudeTranscriptBuilder.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Parsers/ToolInputParser.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Parsers/UserContentParser.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Parsers/ToolResultParser.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Parsers/OffloadedOutputParser.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Parsers/MCPToolNameParser.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Parsers/ImageBlockParser.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Resolvers/*.swift` (all four)
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Dispatchers/*.swift` (all six)
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/ClaudeContentDetector.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/Wire/*.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/TranscriptStream.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Entries/AgentEntry.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Panel/AgentXrayPanel.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Panel/DetailContent.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/EntryBodyView.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/AgentEntryView+CappedBody.swift`

**Re-verify corpus claims.** The design below quotes empirical findings
from corpus surveys conducted during the design discussion. Re-run any
claim-critical greps before finalizing the plan; the corpus may have
grown / shifted between sessions:

- Skill-vs-builtin tag-order check (98.16% match against current
  next-line lookup, +6 plugin-skills caught).
- Queued-prompt content-equality (445/445 byte-exact in last audit).
- Same-timestamp `remove` co-emission (87.2% of consumer attachments).
- Task-notification → bg-bash-completion lifecycle (100% / 197+9 of
  task-notification attachments traced to a prior `<task-notification>`
  enqueue).
- `commandMode` distinct values = exactly `{"prompt", "task-notification"}`.

Re-running these on the current corpus may produce stronger or weaker
percentages but the qualitative shape is stable.

---

## §A — Pre-Phase-G optimization: single-fused resolver walk

**Cheap, lossless, can land independently of Phase G.** Worth doing
first so that perf telemetry on Phase G measures the right baseline.

### Problem

`ClaudeTranscriptBuilder.transcript()` currently runs **five full-buffer
walks** per rebuild:

```
ClaudeBranchResolver.resolve(lines:)        // walk 1
ClaudeTurnDurationResolver.resolve(lines:)  // walk 2
ClaudeQueuedPromptResolver.resolve(lines:)  // walk 3
ClaudeSkillCommandResolver.resolve(lines:)  // walk 4
for line in rawLines { dispatch(line, ctx) } // walk 5
```

Each is O(N) in buffer size. Plus recursive sub-rebuilds for abandoned
branches and sidechain transcripts compound the cost (one main rebuild
on a session with N abandoned branches + M sidechains = (1+N+M) full
rebuilds).

### Fix

Each resolver is a state machine over the line sequence; they're
orthogonal (no cross-resolver state dependency). Fuse into one walk:

```swift
var branchState = BranchResolverState()
var durationState = TurnDurationResolverState()
var queuedState = QueuedPromptResolverState()
var skillState = SkillCommandResolverState()

for line in rawLines {
    branchState.observe(line)
    durationState.observe(line)
    queuedState.observe(line)
    skillState.observe(line)
}

let branchResolution = branchState.finalize()
let turnDurations = durationState.finalize()
let queued = queuedState.finalize()
let skill = skillState.finalize()

// then the dispatch walk runs separately (5 → 2 walks)
```

Each resolver gains an `observe(_ line:)` mutating method + a
`finalize() -> Resolution` method. The current public
`Resolver.resolve(lines:)` becomes a thin convenience wrapper for
backward compatibility / tests:

```swift
extension ClaudeBranchResolver {
    static func resolve(lines: [ClaudeJSONLLine]) -> ClaudeBranchResolution {
        var state = BranchResolverState()
        for line in lines { state.observe(line) }
        return state.finalize()
    }
}
```

### Cost / win

- ~50–100 LOC refactor across 4 resolvers.
- Tests stay green (the public API doesn't change).
- 4 walks of O(N) each → 1 walk × O(N) total. ~75% reduction in resolver-pass work per rebuild.
- No semantic change. No behavior change.

### Verify

After landing, benchmark a synthetic 10K-line session and compare
rebuild-time before/after. Document in MIGRATION_PLAN.md §14.

---

## §B — Phase G: Incremental builder + event-driven update model

The headline architectural change. Replaces the rebuild-from-scratch
model with per-line incremental in-place updates, indexed by entry ID.

### Why

The current `transcript()` rebuilds the full `[Entry]` from
`rawLines: [ClaudeJSONLLine]` on every chunk-batch ingest:

- O(N) resolver passes (after §A: O(N) total instead of 5×O(N)).
- O(N) dispatch walk.
- Recursive sub-rebuilds for abandoned-branch + sidechain transcripts
  compound this.

For typical sessions (~few hundred lines, sub-millisecond rebuilds),
this is fine. For long-running autonomous-agent sessions (~10K+
lines, dozens of background-tool calls, frequent rewinds), the
quadratic-ish total cost over session lifetime becomes noticeable.

The current model also forces conceptual artifacts:
- `PendingTurn` accumulator + `PendingSubEntry` enum exist solely
  because the rebuild treats `[Entry]` as immutable terminal output.
- `subEntryToTopLevel` body-mirror was dead computation (already
  dropped in audit cleanup).
- `flushPendingTurn` projection step is the conversion from
  builder-internal accumulator types to public `AgentEntry.SubEntry`.
- Cross-line resolvers (`ClaudeQueuedPromptResolver`,
  `ClaudeSkillCommandResolver`, `ClaudeTurnDurationResolver`) are
  pre-passes whose state is then consumed at dispatch time.

All of these are vestiges of the rebuild model, not structural
necessities.

### Core architecture

Replace `transcript()` with an event-sourced applier that mutates a
single tree of entries in place.

#### Virtual root + uniform tree

Define a virtual root entry that has only `subEntries`. Top-level
entries become subEntries of root. The whole entry tree becomes
uniform — there's no "top-level vs sub-level" distinction in the
operations:

```
root (synthetic, not rendered)
├── UserEntry (top-level)
├── AgentEntry (top-level)
│   ├── TextSubEntry (.thinking)
│   ├── ToolEntry
│   │   └── (sidechain entries inside Task tool)
│   │       ├── UserEntry
│   │       ├── AgentEntry
│   │       │   └── ...
│   ├── TextSubEntry (.assistant)
│   └── ...
├── SystemEntry
├── SynthesizedEntry (branchLink — wraps abandoned-branch subtree)
└── ...
```

Sub-agent transcripts (Task tool sidechains) and abandoned-branch
subtrees (rewind link bodies) recurse through the same uniform shape.

#### Event types

The dispatcher per line type emits events of three kinds:

```swift
enum EntryUpdate {
    /// Append a new entry under `parentId` (root for top-level).
    case appendEntry(parentId: EntryID, Entry)

    /// Mutate an existing entry by id. Closure receives `inout Entry`.
    case mutateEntry(id: EntryID, (inout Entry) -> Void)

    /// Slice the tail past `divergenceParentUuid` into a branch-link
    /// subtree. Used for rewinds. Inserts the synthesized branch-link
    /// at the divergence point.
    case sliceFromDivergence(parentUuid: String, branchLink: SynthesizedEntry)

    /// No-op (e.g. session-orphan metadata, filtered task-notification).
    case skip
}
```

Per-line dispatchers return `[EntryUpdate]` instead of `ClaudeLineRouting`.

#### Index: parent-chain form

```swift
var entriesById: [EntryID: (parent: EntryID, index: Int)]
```

Every entry — at every depth — has a globally unique ID (verify
against corpus, but per existing scheme: top-level uses JSONL line
uuid; tool sub-entries use Anthropic tool_use_id; thinking/assistant
sub-entries use derived id `parent.id + "thinking-N" / "assistantText-N"`).

Walking from any entry to its location:
- O(depth) — chain hops via `entriesById` lookup, each O(1).
- Depth ≤ 3 in practice (root → agent turn → tool sub-entry → optional
  sidechain sub-entry).

**Why parent-chain over flat IndexPath**: insertion cost. With flat
IndexPath, inserting a new top-level entry at position N invalidates
every descendant's path that starts with `[M]` for M ≥ N. With
parent-chain, only the immediate siblings whose `index` shifted need
updating; descendants' (parent, index) tuples are unchanged because
they're relative to their immediate parent, not absolute from root.

#### Applier

Stateful object that owns the tree + index map:

```swift
struct EntryApplier {
    var root: VirtualRootEntry  // only carries subEntries
    var entriesById: [EntryID: (parent: EntryID, index: Int)]

    mutating func apply(_ update: EntryUpdate) {
        switch update {
        case .appendEntry(let parentId, let entry):
            // Walk parent chain to find the parent's subEntries array.
            // Append. Record (parent, newIndex) in entriesById for
            // entry.id and recursively for any sub-entries the new
            // entry already carries.
            ...
        case .mutateEntry(let id, let mutation):
            // entriesById[id] → walk parent chain → mutation(&slot).
            // Re-record entry.id's mapping if the entry has sub-entries
            // whose paths might have changed (mutation may add/remove).
            ...
        case .sliceFromDivergence(let parentUuid, let branchLink):
            // Find divergence point (entriesById[EntryID.fromJSONL(parentUuid)]).
            // Slice everything past it into branchLink.body.subentries.
            // Replace tail with [.synthesized(branchLink)].
            // Rebuild entriesById for the affected slots.
            ...
        case .skip:
            return
        }
    }
}
```

### Per-line dispatcher → events

Each dispatcher in `Adapters/Claude/Dispatchers/` returns events:

```swift
enum UserLineDispatcher {
    static func updates(for line: ClaudeJSONLLine, state: ApplierState) -> [EntryUpdate] {
        // ... content sniff + parent-chain inspection + state lookup
        // Returns [.appendEntry(parentId: rootId, ...)] for new user lines,
        // [.mutateEntry(id: pendingPromptId, ...)] for queued-prompt consumers, etc.
    }
}
```

Where `ApplierState` is a read-only view of `entriesById` + the
`pendingPromptIds` mirror queue + branch state.

The current `ClaudeLineRouting` enum disappears. The dispatcher returns
concrete update events directly.

#### Per-resolver migration

Each existing resolver becomes a per-line state machine that the
dispatcher consults:

| Current resolver | Migration |
|---|---|
| `ClaudeBranchResolver` | Stateful object cached in applier. Updates active-branch UUID set on each new line. Detects new `last-prompt` markers → emits `sliceFromDivergence` events. |
| `ClaudeTurnDurationResolver` | Per-line: when a `system.subtype:turn_duration` line arrives, look up parentUuid's AgentEntry by id and emit `mutateEntry(id:, { $0.perTurnDurationMs = … })`. |
| `ClaudeQueuedPromptResolver` | Replaced by inline FIFO mirror (see §C). |
| `ClaudeSkillCommandResolver` | **Disappears** — replaced by per-line tag-order check (see §D). |

### Pending-turn collapse

`PendingTurn` accumulator + `PendingSubEntry` enum disappear. The
"pending turn" becomes simply "the latest AgentEntry being mutated":

- New `assistant`-typed JSONL line arrives:
  - If the latest top-level entry is an AgentEntry from the same
    turn (parentUuid chain matches), emit
    `appendEntry(parentId: thatAgent.id, …)` to add a new sub-entry.
  - Else emit `appendEntry(parentId: rootId, AgentEntry(…))` to start
    a new turn.
- New `tool_use` block arrives (inside an assistant content[]):
  emit `appendEntry(parentId: agentTurnId, ToolEntry(…, status: .pending, result: nil))`.
- New `tool_result` block arrives (inside a user content[]):
  emit `mutateEntry(id: EntryID.fromJSONL(toolUseId), { $0.result = …; $0.status = .ok })`.

No flush step. No accumulator-to-final-projection. The latest
AgentEntry IS the live state.

### Token / duration / model aggregation

Currently `flushPendingTurn` aggregates these from PendingTurn fields.
With incremental: each new assistant line emits a `mutateEntry` event
that updates the running totals on the open AgentEntry. Trivial.

### Sidechain attachment

Sidechain (sub-agent) lines currently flow through
`ctx.sidechainLinesByParent[parent].append(line)` and attach in
`flushPendingTurn`'s tail. With incremental:

- Sidechain line arrives: emit `appendEntry(parentId: parentToolId, …)`
  where `parentToolId` is the parent Task tool's EntryID.
- Sub-agent runs its own builder logic recursively under the parent
  Task tool's tree.

The recursive sub-builder collapses into "same applier, deeper parentId."

### Branch-link synthesis

Triggered by `last-prompt` marker arrival (handled by branch-state-as-
state-machine). When a new marker arrives:

1. State machine identifies divergence point (parent uuid).
2. Emits `sliceFromDivergence(parentUuid: divPoint, branchLink:
   SynthesizedEntry)` event.
3. Applier slices the tail into the branch-link's
   `body.subentries`. Inserts the branch-link at divergence.

**Nested rewinds work for free.** If a previous rewind had inserted
branch-link-1 into the tail, and a new rewind slices a tail that
includes branch-link-1, the slice naturally captures branch-link-1
inside branch-link-2's `body.subentries`. Click into branch-link-2 →
see its subtree → click branch-link-1 inside → drill deeper. No
folding logic.

### Performance characterization

| Operation | Today | Phase G |
|---|---|---|
| Single-line ingest | O(N) — full rebuild + 5 walks | O(1) amortized — index lookup + append |
| Chunk-batch ingest of K lines | O(N) per batch | O(K) per batch |
| Total session lifetime cost | O(B × N) where B = #batches, N = buffer size | O(N_total) where N_total = total lines |
| Rewind | Full rebuild | O(K_tail) where K_tail = abandoned-segment size |
| Sidechain line | Recursive full sub-rebuild | O(1) — same applier, deeper parent |

For typical small sessions (~few hundred lines), the difference is
sub-millisecond — not user-visible. For long-running autonomous-agent
sessions (10K+ lines, frequent background tools), the savings
compound dramatically.

### Tests

Test pattern shifts from "build full transcript, assert" to "given
applier state, apply event, assert state." Each test still small and
pure; each event test is independent.

Migration plan for existing builder tests:
- Most of `ClaudeTranscriptBuilderTests` continues to work
  unchanged — they ingest a synthetic line array and assert on
  `transcript()` output. `transcript()` becomes a convenience that
  applies all events and returns `entries`.
- New tests cover applier state transitions per event type.
- Specific regression coverage for: same-id duplicate tool_use
  blocks (current code overwrites; new code mutates), turn-boundary
  detection (parentUuid chain logic), nested-rewind nesting,
  sidechain recursive append.

### Risks / things to verify before drafting plan

1. **Entry ID uniqueness in corpus.** Every entry at every depth must
   have a globally unique id within a session. Top-level uses JSONL
   line uuid; tool sub-entries use Anthropic-minted tool_use_id;
   text sub-entries use derived `parent + "thinking-N"` /
   `"assistantText-N"`. Run a corpus survey: for 50 sessions, collect
   all uuids + tool_use_ids and check for duplicates. Sample lines
   that have intra-session collisions if any. Fall back if assumption
   doesn't hold.
2. **Same tool_use_id appearing twice in a session.** Current
   `PendingTurn.toolIndexByID` overwrites on duplicate. Verify in
   corpus how often this happens (likely rare, intra-turn duplicate
   only) and confirm in-place mutation handles it correctly (last-
   write-wins, same as today).
3. **Cross-session uuid collisions.** Less important (sessions
   independent in package state) but verify there's no infrastructure
   that aggregates entries across sessions.
4. **Sidechain id space.** When a Task tool spawns a sub-agent, the
   sidechain's lines have their own JSONL uuids. Confirm the id
   space is consistent (same uuid format) and they don't collide
   with the parent session's. Likely they're session-scoped to the
   parent's session, but verify.

These are short corpus checks (single-digit minutes each). Land them
as Plan agent dispatches before the implementation pass starts.

### Estimated scope

- ~400-600 LOC across builder + dispatchers + 3 resolver rewrites.
- ~50-80 test changes (migration of existing tests + new applier tests).
- Single big PR or split across 3-4 sub-commits:
  1. Single-fused resolver walk (§A) — independent, lands first.
  2. Applier + index map + virtual root infrastructure.
  3. Per-line dispatcher migration (each dispatcher → events).
  4. PendingTurn / PendingSubEntry collapse + recursive sidechain.
  5. Branch-resolver state-machine migration + slice events.

---

## §C — Queued-prompt redesign (lands inside Phase G)

The current `ClaudeQueuedPromptResolver` is a cross-line pre-pass that
matches enqueue lines to consumers via content-string equality. With
the incremental model, it becomes an inline FIFO mirror queue that
the user-line dispatcher maintains.

### Lifecycle

Three stages, simpler than today:

- `.queued` — synthetic UserEntry visible in transcript with the
  queued-decoration icon (`person.badge.clock` /
  `person.badge.clock.fill`). User feedback that "your typed-while-busy
  prompt is in the queue."
- (consumer arrives) → either remove the synthetic entry or hide it
  (audit recommends remove; index map updates accordingly).
- The consumed user message renders as a normal UserEntry with the
  consumed-queued-decoration icon (`person.fill.badge.clock` /
  `person.fill.badge.clock.fill`).

### Three-rule matching, no look-ahead, no tracking of `remove`

Filter both ends of the task-notification channel; drive consumption
from the attachment line:

```swift
// 1. queue-op enqueue:
if content.hasPrefix("<task-notification>") {
    return .skip   // drop entirely — neither track nor render
}
// User-typed enqueue:
let id = EntryID.synthesized()
return [.appendEntry(parentId: rootId, UserEntry(id: id, queuedState: .queued, content: content))]
// + push id to applier's pendingPromptIds FIFO

// 2. queue-op remove / dequeue / popAll:
return .skip   // ignore entirely — consumption is driven from the attachment

// 3. attachment.queued_command:
switch attachment.commandMode {
case "task-notification":
    return .skip
case "prompt":
    var events: [EntryUpdate] = []
    if let head = pendingPromptIds.first {
        pendingPromptIds.removeFirst()
        events.append(.mutateEntry(id: head, { /* mark consumed or remove */ }))
    }
    events.append(.appendEntry(
        parentId: rootId,
        UserEntry(content: attachment.prompt, icon: queuedDecorated)
    ))
    return events
}
```

### Why this works

Task-notifications and user-typed prompts share Claude's FIFO queue.
But by filtering BOTH the task-notification enqueue AND the
task-notification attachment, our mirror queue only ever holds
user-typed entries. Each `commandMode: "prompt"` attachment pops one
head — exact pairing.

Walked through both interleavings:
- B-first FIFO (user typed first, bg task finished second): pop B on
  prompt attachment; bg task's enqueue+remove+attachment all dropped.
- task-notif-first FIFO (bg task finished first, user typed second):
  task-notif's enqueue+remove+attachment all dropped; user-typed B
  enqueued; remove ignored; pop B on prompt attachment.

Both correct.

### Verify

- Confirm `commandMode` distinct values are still exactly `{"prompt",
  "task-notification"}`.
- Sanity-check that **every** `<task-notification>` enqueue has a
  corresponding `commandMode: "task-notification"` consumer (or no
  consumer in the case of session-end / popAll). The audit found
  543 task-notification enqueues vs 206 surfaced attachments — the
  rest never reach the model. That's fine; our filter handles both
  cases.

### task-notification semantics (for documentation)

**`task-notification` is the completion-edge of `Bash(run_in_background: true)`.**
When a backgrounded process exits, Claude Code synthesizes a queued
user-message in a fixed XML envelope:

```xml
<task-notification>
  <task-id>X</task-id>
  <tool-use-id>toolu_...</tool-use-id>
  <output-file>/tmp/.../tasks/X.output</output-file>
  <status>completed|failed</status>
  <summary>Background command "..." completed (exit code 0)</summary>
</task-notification>
```

The notification rides the queue mechanism (same `enqueue → remove →
attachment` lifecycle as user-typed prompts) so it lands at a clean
turn boundary instead of mid-tool-use. It tells the model "the bg
task you launched is done; if you want details, read the output
file." Without it, `run_in_background: true` would return only the
synchronous "Command running in background with ID: X" line and the
model would never know to read the output.

This semantic explanation should land as a comment in the new
queued-prompt code path so future maintainers understand why
filtering is correct.

---

## §D — Skill-vs-builtin discriminator simplification (lands inside Phase G)

The current `ClaudeSkillCommandResolver` uses next-line lookup:
"a skill's `<command-message>` user line is followed in file order
by an `isMeta:true` user line whose first text block starts with
'Base directory for this skill:'". Two-line peek; awkward in
incremental.

Replace with a single-line tag-order check on the user line itself:

```swift
let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
let isSkill = trimmed.hasPrefix("<command-message>")
```

Skills emit `<command-message>` first (flush-left). Builtins emit
`<command-name>` first (with subsequent tags 12-space-indented).

### Corpus validation (verify before landing)

- 98.16% match with current discriminator (TP=123, TN=197, FP=6, FN=0).
- The 6 "false positives" are `/simplify`, `/claude-hud:configure`,
  `/claude-hud:setup`, `/install-mcps` — **all genuinely skills the
  current rule misses** (they don't emit "Base directory for this
  skill:" because their plugin shape uses different metadata).
- 0 false negatives.

So the new discriminator is **strictly more correct**. Bug fix +
simplification, not just simplification.

### What disappears

- `ClaudeSkillCommandResolver` entire file.
- `skillCommandUuids: Set<String>` parameter threading through
  `ClaudeLineDispatcher.route(...)` and downstream.
- The look-ahead requirement on the resolver pass.

### What replaces it

A single-line helper inlined into `UserLineDispatcher`:

```swift
private static func isSkillShaped(_ line: ClaudeJSONLLine) -> Bool {
    guard let raw = line.message?.content?.firstText() else { return false }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("<command-message>")
}
```

Caveat: re-verify the corpus signal. Both shapes are produced by Claude
Code's slash-command renderer, so this is a stable internal convention.
If Anthropic re-orders tags in a future Claude Code release, both the
current and the proposed discriminator break — but the new one breaks
no harder than the current rule.

---

## Recommended phasing

Land in this order to keep each commit independently reviewable:

| Phase | Sub-task | Cost | Independent? |
|---|---|---|---|
| 1 | §A single-fused resolver walk | small | ✓ — can ship before Phase G |
| 2 | §D skill-discriminator tag-order rewrite | small | ✓ — pure bug-fix improvement, ship before Phase G if desired |
| 3 | Phase G core: virtual root + applier + index map + event types | medium | new infrastructure; no consumers yet |
| 4 | Per-line dispatchers migrated to event-emitting | medium-large | depends on (3) |
| 5 | PendingTurn collapse + recursive sidechain | medium | depends on (4) |
| 6 | Branch-resolver as state machine + slice events | medium | depends on (3); rewinds become incremental |
| 7 | Queued-prompt §C redesign | small-medium | depends on (4) |
| 8 | Drop dead code: `subEntryToTopLevel` (already gone), accumulator types, old resolver class | small | cleanup |

Each step should keep the current `transcript()` working as a
convenience wrapper that applies all events and returns the resulting
entries — that way existing tests stay green throughout.

---

## Carry-forward (older deferrals — lower priority)

Still tracked from prior handovers. None block Phase G.

### Richer transcript renderer (FU 3 from Phase D-rev)

Sub-agent + abandoned-branch transcripts still render in-package via
`TranscriptView.detailEntriesList`. Future enhancement: sticky turn
header, per-turn stats, search-in-transcript, fold-to-headings,
diff-vs-parent for abandoned branches. Out of scope for Phase G.

### Screenshot vs Image discrimination (small)

Inline label is universally "Image" today. Discriminating "Screenshot"
specifically (for tool-result images from `browser_take_screenshot`-shaped
tools) needs the tool name threaded into `ToolResultParser`. Small
follow-up. Independent of Phase G.

### Pane placement fine-tuning

`AgentXrayWorkspaceHost.openFileInPanel` uses cmux's default placement
(`activate: false`, focused pane). One-line change tunable. Independent.

### Audit deferred items

- **S3** — `buildSystemEntry` and `buildCompactEntry` silently drop
  images (use `allText()` projection). Corpus has 0 hits; deferred.

### `AgentXrayPanel.detail` mode shape

Used only for transcript content now (post-Phase-E). A future phase
may decide whether the detail mode itself is still warranted given
that transcripts could become a separate cmux panel kind. Out of scope.

---

## Cross-doc map

| Doc | Role |
|---|---|
| `README.md` | Package overview, vocabulary, layer map, host integration. |
| `MIGRATION_PLAN.md` | Per-phase commit ledger (§14), bug-fix ledger (§15), deferred-by-policy items (§16), origin cross-reference (§18). |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (§11 has the canonical block-type table). |
| `docs/session-attach.md` | Session-attach resolver flow. |
| `docs/next-session-handover.md` | **(this doc)** Phase G architecture redesign + queued-prompt + skill discriminator. |

If any doc disagrees with the code, the code wins — fix the doc in
the same change.
