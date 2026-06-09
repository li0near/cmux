# Claude Code JSONL — corpus survey

Empirical findings about the Claude Code session JSONL format,
gathered across multiple Phase G corpus audits. This doc captures
the wire shapes, chaining patterns, ordering invariants, and the
"rare but real" edge cases that the AgentX-ray streaming dispatcher
must handle.

**Reads like a spec, but isn't one.** Claude Code's wire format is
not publicly documented; this is reverse-engineered from real
sessions. Every empirical claim here was true at scan time;
**re-validate before relying on a number** — Claude Code releases
introduce shape changes silently, and one audit in this round
proved a prior corpus survey wrong (see "Empirical invariants" §).

## Where the data lives

`~/.claude/projects/<project-slug>/<session-uuid>.jsonl` — one
session per file, NDJSON (newline-delimited JSON, one object per
line). Files are append-only during a live session; rewinds, queue
operations, and tool results all land as new lines, never as
in-place edits.

## Line types

Every line carries `type: String` plus per-type fields. Observed
types:

| Type | Purpose | Notes |
|---|---|---|
| `user` | User-typed prompts; tool_result wrappers; meta-noise injections (`<system-reminder>`, `<local-command-*>`, etc.); slash-command inputs (newer Claude Code emits these as `user` with `isMeta: null` instead of `isMeta: true`). |
| `assistant` | Claude's response — text, thinking, tool_use content blocks. Streamed as multiple lines per logical turn (one content block per line is the modern norm). |
| `system` | Per-turn telemetry. Subtypes: `turn_duration` (parentUuid = last assistant message; carries durationMs + messageCount), `away_summary` (recap row), `compact_boundary` (compact event marker), `local_command` (built-in slash command input/output), plus open-ended generic subtypes (`api_error`, `stop_hook_summary`, `informational`, etc.). |
| `attachment` | User-visible session events. Subtypes: `queued_command` (consumed queued prompt), `plan_mode` / `plan_mode_exit` / `plan_mode_reentry`, `edited_text_file`. |
| `queue-operation` | Queue lifecycle. Operations: `enqueue` (carries content), `dequeue`, `remove`, `popAll` (no per-item id; treat the queue stream as opaque FIFO). |
| `last-prompt` | Active-leaf marker. **97% noise** (Audit 2 — see below); ignore for routing. |
| `pr-link` | External GitHub PR reference. Renders as a synthesized link row. |
| `permission-mode`, `agent-name`, `custom-title`, `file-history-snapshot`, `progress` | Session-orphan metadata. Skip — no parentUuid, no renderable body. |
| `summary` | Compact event marker (older flow). Routes to `CompactEntry`. |

## Universal fields

Every line carries:

- `uuid`: line's own identifier. **Not always populated** — some
  metadata types (e.g. `progress`) emit lines without a uuid; build
  a stable id by hashing line content for those.
- `parentUuid`: the previous line's uuid in the conversation chain.
  `null` for session-start lines and most session-orphan metadata.
- `timestamp`: ISO-8601 wall clock. Optional in rare cases.
- `sessionId`: present on most types; not relied on for chain
  resolution.

Per-type variants:

- `assistant`/`user`: `message: { role, content, model?, stop_reason?, usage?, id? }`. `content` is either `String` or `[ContentBlock]`.
- `system`: `subtype: String`, `content: String?`, plus subtype-specific fields (`durationMs`, `messageCount`, etc.).
- `attachment`: `attachment: { type, prompt?, planFilePath?, filename?, snippet?, commandMode?, ... }`.
- `queue-operation`: `operation: String`, `content: String?`.
- `pr-link`: `prNumber: Int`, `prUrl: String`, `prRepository: String`.

## parentUuid chaining

Every active line points at a real prior line's uuid via `parentUuid`.
The chain weaves through whatever blocks land in sequence —
`user → thinking → tool_use → tool_result(user) → text → tool_use → ...`.

**Verified shape (representative session):**

```
line 3:  uuid=ab472580 parent=5c01d69a kinds=['thinking']
line 4:  uuid=4e7d3d07 parent=ab472580 kinds=['tool_use']    ← parent = line 3
line 7:  uuid=fbf6b44f parent=f94d124b kinds=['thinking']
line 8:  uuid=b63541c6 parent=fbf6b44f kinds=['tool_use']    ← parent = line 7
line 14: uuid=182e9d98 parent=96e71f00 kinds=['text']
line 20: uuid=41844928 parent=12fd0e8b kinds=['text']
line 21: uuid=0575459c parent=41844928 kinds=['tool_use']    ← parent = line 20
```

The previous line's `uuid` IS the resolution target — no skeleton
lookup or chain walk needed if the streaming dispatcher uses each
line's `stableId` as its entry id.

## Content-block shape (assistant + tool_result)

Assistant lines and tool_result-bearing user lines carry
`message.content` as either:

- `String` (legacy text-only path).
- `[ContentBlock]` where each block has a `type` discriminator:
  `text` / `thinking` / `tool_use` / `tool_result` / `image`.

`tool_use` blocks carry `id` (the `tool_use_id`), `name`, `input`.
`tool_result` blocks carry `tool_use_id` (back-reference) and
`content` (the result payload — text or image blocks).

**Single-block-per-assistant-line is the modern norm** (verified
99.97% across 200 files / 31,267 lines). Multi-block lines do
occur — the dispatcher must handle N blocks per line, with the
N-th block of a kind getting a derived id suffix
(`thinking-0`, `thinking-1`, etc.) for tie-breaking.

## Slash-command surfaces

Two-prefix discrimination:

- `<command-message>...</command-message>`: plugin / user-defined
  skill (e.g., `/aicore-api`, `/simplify`, `/claude-hud:configure`).
- `<command-name>...</command-name>`: built-in slash (e.g., `/exit`,
  `/clear`, `/agents`, `/branch`).

Both shapes can appear on `user` lines with `isMeta: true` (older
Claude Code) OR with `isMeta: null` (newer). The wrapper text
itself is not the rendered output — the dispatcher reconstructs
`/cmd args` from `<command-name>` + `<command-args>` for FIFO
matching against earlier `queue-operation enqueue` content.

## Queued-prompt flow

`queue-operation enqueue` lines carry the typed text in `content`
plus a `timestamp`. The text gets consumed by:

- `attachment.queued_command` (most common): typed prompt picked
  up by Claude after the in-flight turn finishes.
- Slash-command user line: typed prompt fired as a slash-command;
  also surfaces as a consumer.

**Both consumer paths exist in the corpus.** A prior brief asserted
only `attachment.queued_command` consumes; this was empirically
disproved during a Phase G dogfood (a queued `/aicore-api` surfaced
as a slash-cmd user line with no `attachment.queued_command`
follow-up). The streaming dispatcher consumes from both.

`task-notification`-prefixed enqueues are completion echoes for
`Bash(run_in_background: true)` — filter at intake; they ride the
queue but never surface as user prompts.

## Rewinds & branching

When the user uses Claude's rewind feature, the new user prompt's
`parentUuid` points back to a prior conversation node — abandoning
whatever ran past that point.

**Three converging audits established the structural signal:**

- **Audit 1** (420 rewinds / 97 sessions): rewind iff new
  user-prompt's `parentUuid` is NOT in the previous user-prompt's
  descendant tree. **0 / 420 match a `last-prompt` marker.**
- **Audit 2** (5,849 `last-prompt` markers across the corpus): only
  ~2.8% (156) correspond to rewinds. The other 97.2% are
  session-resume / permission-checkpoint hints — **noise**.
- **Audit 3** (306 rewinds / 82 sessions): 100% structurally present
  as "user-prompt's parentUuid points at a node that already has an
  earlier user-prompt child." Zero parallel-tool-call false
  positives.

Slice operations are **top-level + tail-only**: 200 sampled
sessions, 85/85 rewinds abandon a contiguous tail past the
divergence point; 0 mid-array slices observed. The
`Transcript.branchOff(at:link:)` API enforces top-level via the
`divPath.count == 1` check.

## Out-of-order anomalies

In rare cases a line's `parentUuid` references a uuid that hasn't
been written to the file yet (write-order vs topological-order
divergence).

**Last scan (200 files / 31,267 lines):** 12 / 31,267 ≈ 0.04% of
lines were out-of-order.

**Empirically wrong claim** that an earlier scan made: an initial
731-session survey reported "0 sessions with 2+ children waiting on
the same parent." This claim crashed live during a Phase G dogfood —
a real session produced 2+ children pending on the same missing
parent within minutes of opening. The survey was wrong; the
streaming dispatcher's pool MUST be `[String: [Line]]` (array per
parent), not single-value.

**Lesson recorded:** corpus surveys can miss session shapes that
aren't rare in practice. Default: when a brief asserts a corpus
invariant, structure the code to handle the violation gracefully
(array, not single-value) and re-verify with a fresh sample at
implementation time.

## Skipped-decorator anchoring

Some assistant lines have `parentUuid` pointing at types we skip
(`permission-mode`, `file-history-snapshot`, `agent-name`, etc.).
**~3.21% of assistant lines in the 200-file scan** parent on a
skipped decorator.

If the dispatcher doesn't alias skipped lines to *something* in
the index, every descendant cascades into the pending pool forever
and the transcript renders empty. Fix: when a skipped line has a
`uuid`, register an alias to its own parent's path (or to `[]`
empty path if the parent isn't resolvable either). Children of
orphan-anchored lines then fall through to fresh top-level append
naturally.

## Sidechain (sub-agent) shapes

Lines emitted by sub-agents (Task / Agent tool spawns) carry
`isSidechain: true` and a `parentToolUseID` referencing the parent
turn's `tool_use_id`.

**Sidechain corpus survey** (710 sessions, 36,113 sidechain lines):

- **0 uuid collisions** between sidechain and parent-session lines.
  Unified `EntryID` index is collision-free for complete sessions.
- 204 orphan `parentToolUseID` references in 16 sessions — all in
  subagent files where the parent `messages.jsonl` is missing
  (incomplete corpus; not data corruption).

Phase G ships sidechain handling as `.skip` — the proper "sub-agent
as nested AgentEntry" surfacing is deferred future work.

## tool_use_id uniqueness

The Anthropic API spec implies `tool_use_id` is unique per session.
Two early Phase G fixtures pinned legacy "duplicate-tool_use
overwrite" and "cross-turn id reuse" behaviors — both rely on
non-uniqueness, which contradicts the spec. **The fixtures were
dropped in G6.** If a real session produces a duplicate
`tool_use_id`, that's a Claude bug to escalate, not a behavior to
preserve.

## Wire-shape gotchas

- `compact_boundary` lines have `parentUuid: null` but carry
  `logicalParentUuid` pointing at the pre-compaction tail. Treat
  the logical link as the effective parent so chain-walks stitch
  the active branch across the compact event.
- `image` blocks emitted by the **assistant** are spec-allowed but
  **never observed in corpus** (verified 2026-06-07: 0 hits in
  scanned sessions). Real images flow back via `tool_result`
  (e.g. Playwright `browser_take_screenshot`) or via top-level
  user paste, both handled in dedicated paths.
- `<task-notification>` prefix on queued enqueues marks the
  completion edge of `Bash(run_in_background: true)` — filter both
  ends (don't push to FIFO; don't surface as a UserEntry).
- Synthetic assistant lines (`message.model == "<synthetic>"`) are
  fabricated by Claude Code for interrupt stubs (`"No response
  requested."`), API-error envelopes, and partial-response
  cutoffs. Drop them — they should not produce an `AgentEntry`.

## Methodology

The audit numbers in this doc come from offline scans across
`~/.claude/projects/`. Different audits sampled at different points
during Phase G's development; the table below records the relevant
ones.

| Audit | Scope | Finding |
|---|---|---|
| Audit 1 | 420 rewinds / 97 sessions | 0/420 rewinds match a `last-prompt` marker. |
| Audit 2 | 5,849 markers / corpus | 97.2% are session-resume / permission noise; only 2.8% rewind-adjacent. |
| Audit 3 | 306 rewinds / 82 sessions | 100% rewind = "parentUuid → earlier user-prompt child" structural signal. |
| Sidechain survey | 710 sessions / 36,113 sidechain lines | 0 uuid collisions; 204 orphan `parentToolUseID` (all incomplete-corpus). |
| Top-level + tail-only slice | 200 sessions / 85 rewinds | 100% top-level; 100% contiguous tail past divergence. |
| Single-block-per-line | 200 files / 31,267 lines | 99.97% single-block. |
| Out-of-order parents | 200 files / 31,267 lines | 12 ≈ 0.04% out-of-order. |
| Skipped-decorator anchoring | 200 files | ~3.21% assistant lines parent on a skipped type. |
| Pool multi-child invariant | 731 sessions / 172,470 lines | **EMPIRICALLY WRONG** — claimed 0; live dogfood disproved. |

Scan scripts are short (one-shot Python over the `~/.claude/projects/`
tree). They live in `/tmp/` during the audit; not checked in. Re-run
on demand when validating a brief's invariants.

## Maintenance

Append new findings here as future Phase G follow-ups (and Codex
adapter work) surface them. Keep entries dated and source-cited.
When a claim is invalidated, **leave the original line and add a
correction line below** rather than silently editing — the audit
trail matters when the next session is debugging "why did I think
X was true?"
