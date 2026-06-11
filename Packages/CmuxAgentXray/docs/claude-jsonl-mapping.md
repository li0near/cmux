# Claude JSONL → Entry mapping

How `CmuxAgentXray` decodes Claude Code session JSONL files and projects
each line into the rendered transcript. This is the maintenance reference
for the dispatcher, parsers, and resolvers under
`Sources/CmuxAgentXray/Adapters/Claude/`.

## 1. Claude Code JSONL on disk

Each Claude Code session writes one JSONL file at:

```
~/.claude/projects/<dir-encoded-cwd>/<sessionId>.jsonl
```

- `<dir-encoded-cwd>` is the session's working directory with `/`
  replaced by `-` (e.g. cwd `/Users/me/temp/github/cmux` →
  `-Users-me-temp-github-cmux`).
- `<sessionId>` is a UUID. One file per session.
- A "project" in Claude Code's vocabulary is the parent directory
  grouping every session for one cwd. Multiple worktrees / sibling
  clones produce multiple project directories.
- Lines are append-only. File order is conversation order. Rewinds add
  new lines on a fresh branch and rewrite the active leaf via a
  `last-prompt` marker; nothing is ever deleted.

We tail these files read-only via `JSONLTail` in `Streaming/`. We do
not write to them.

## 2. Line type universe

Every JSONL line decodes to `ClaudeJSONLLine` (`Adapters/Claude/Wire/ClaudeJSONLLine.swift:20`).
Two groups by tree affiliation:

**Tree-affiliated** (carry `parentUuid`; participate in the rewind tree):

| `type`       | role |
|--------------|------|
| `user`       | user prompts, tool results, slash-command wrappers |
| `assistant`  | model text, thinking, tool_use blocks |
| `system`     | turn metadata, hook output, recap, compact boundary |
| `attachment` | structured annotations (queued prompts, plan-mode, edited files) |
| `progress`   | sub-agent hook telemetry (skipped) |

**Session-orphan** (no `parentUuid`; session-global metadata):

| `type`                   | role |
|--------------------------|------|
| `last-prompt`            | active-leaf marker; pointed at by branch resolver |
| `permission-mode`        | session permission state |
| `file-history-snapshot`  | file backup index |
| `agent-name`             | display rename |
| `custom-title`           | session title |
| `pr-link`                | PR linkage payload |
| `queue-operation`        | enqueue/remove/dequeue prompt-queue events |

Decoding ignores unknown fields, so future-Claude additions don't crash —
they fall through to the dispatcher's "unknown type" arm and emit a DEBUG
log warning.

## 3. Our data model

The decoded line drives a three-stage pipeline:

```
JSONL line
   │
   ▼
┌──────────────────────┐         ┌──────────────────────────┐
│ Pre-pass resolvers   │ ◀──── all rawLines (read N×)
│ (pure value funcs)   │
└──────────┬───────────┘
           │ active branch UUIDs, turn-duration stamps,
           │ queued-prompt UUIDs + pending descriptors,
           │ skill-shaped command UUIDs
           ▼
┌──────────────────────┐
│ ClaudeLineDispatcher │ ────▶  ClaudeLineRouting (skip / sidechain /
│ .route(line, …)      │         render(.user|.agent|.system|.compact)
└──────────┬───────────┘         / renderSpecial(<one of 14 special kinds>))
           │
           ▼
┌──────────────────────┐
│ ClaudeTranscriptBldr │ ────▶  Entry  (.user / .agent / .system /
│ .dispatch(line, …)   │              .compact / .synthesized)
└──────────────────────┘
```

`ClaudeLineRouting` (`ClaudeLineDispatcher.swift:5`) is the single
boundary between routing and rendering. Adding a new branch to a parser
means adding a `ClaudeLineRouting` case (or reusing an existing one)
plus the matching emitter in `ClaudeTranscriptBuilder.emitSpecial`.

## 4. Tree form — every dispatch branch

```
ClaudeLineDispatcher.route(line)                                            ClaudeLineDispatcher.swift:69
│
├── CommonLineDispatcher.parse(line)                                            Dispatchers/CommonLineDispatcher.swift:32
│   ├── isSessionOrphanMetadata == true                       → .skip       Wire/ClaudeJSONLLine.swift
│   ├── isLastPromptMarker (type == "last-prompt")            → .skip       Wire/ClaudeJSONLLine.swift
│   ├── type ∈ {permission-mode, agent-name, custom-title,
│   │           queue-operation, file-history-snapshot,
│   │           last-prompt, progress}                        → .skip
│   ├── type == "pr-link"                                     → .renderSpecial(.prLink)
│   └── otherwise                                              → fall through
│
├── isSidechain == true                                       → .sidechainMain  (sub-agent pool, keyed by parentToolUseID)
│
├── type == "user"  ── UserLineDispatcher.parse(line)                           Dispatchers/UserLineDispatcher.swift:13
│   ├── isCompactSummary == true                              → render(.compact)
│   ├── uuid ∈ skillCommandUuids (resolver output)            → render(.user)   (skill-shaped slash command)
│   ├── isMeta == true OR content starts with
│   │   "<command-name>"/"<command-message>"                  → routingForMetaUser:
│   │   ├── content has tool_result block                                    → render(.agent)
│   │   ├── classify(text) == .slashCommandInput              → renderSpecial(.slashCmdInput)
│   │   ├── classify(text) == .slashCommandOutput             → renderSpecial(.slashCmdOutput)
│   │   ├── classify(text) == .systemReminder                 → renderSpecial(.systemReminder)
│   │   ├── classify(text) == .skillInvocation                → renderSpecial(.skill)
│   │   ├── classify(text) == .contextUsage                   → renderSpecial(.contextUsage)
│   │   ├── classify(text) == .continueResume                 → .skip
│   │   ├── classify(text) == .localCommandCaveat             → .skip
│   │   └── classify(text) == .unknown                        → renderSpecial(.unknownMeta)
│   └── otherwise                                              → render(.user)
│       └── ClaudeTranscriptBuilder.classify(line) further refines:        ClaudeTranscriptBuilder.swift:949
│           ├── text starts with "[Request interrupted by user…"            → agent
│           ├── text == empty stdout/stderr envelope                        → hardNoise (skip)
│           ├── text starts with <local-command-stdout/stderr>              → system
│           ├── text wrapped in <local-command-caveat>/<system-reminder>    → hardNoise
│           ├── blocks contains tool_result                                 → agent
│           └── otherwise                                                    → user
│
├── type == "assistant" ── AssistantLineDispatcher.parse(line)                  Dispatchers/AssistantLineDispatcher.swift:14
│   ├── message.model == "<synthetic>"                        → .skip       (interrupt stub, partial cutoff)
│   └── otherwise                                              → render(.agent)
│
├── type == "system" ── SystemLineDispatcher.parse(line)                        Dispatchers/SystemLineDispatcher.swift:13
│   ├── subtype == "turn_duration"                            → .skip       (consumed by ClaudeTurnDurationResolver)
│   ├── subtype == "away_summary"                             → renderSpecial(.recap)
│   ├── subtype == "compact_boundary"                         → render(.compact)
│   ├── subtype == "local_command":
│   │   ├── content starts with <command-name>/<command-message>            → renderSpecial(.slashCmdInput)
│   │   ├── content starts with <local-command-stdout>/<…stderr>           → renderSpecial(.slashCmdOutput)
│   │   └── otherwise                                                       → render(.system)
│   ├── subtype ∈ {api_error, stop_hook_summary, informational}            → render(.system)
│   └── otherwise (unknown subtype)                            → render(.system)   (catch-all so nothing disappears)
│
├── type == "attachment" ── AttachmentLineDispatcher.parse(line)                Dispatchers/AttachmentLineDispatcher.swift:15
│   ├── attachment.type == "queued_command":
│   │   ├── attachment.commandMode == "task-notification"     → .skip       (harness echo of background-task completion)
│   │   └── otherwise                                          → renderSpecial(.queuedPrompt)
│   ├── attachment.type == "plan_mode"                        → renderSpecial(.planModeEntered)
│   ├── attachment.type == "plan_mode_exit"                   → renderSpecial(.planModeExited)
│   ├── attachment.type == "plan_mode_reentry"                → renderSpecial(.planModeReentered)
│   ├── attachment.type == "edited_text_file"                 → renderSpecial(.editedTextFile)
│   └── otherwise (hook_success, task_reminder, diagnostics,
│                   skill_listing, deferred_tools_delta,
│                   command_permissions, date_change,
│                   hook_non_blocking_error, …)               → .skip
│
└── unknown type                                              → DEBUG log + .skip
```

After dispatch, `ClaudeLineDispatcher.branchGated` (`ClaudeLineDispatcher.swift:116`)
wraps every render decision: when `activeBranchAvailable == true` and
the line's UUID is **not** in `activeBranch`, the routing is rewritten
to `.skipBranchAffiliated` and the line surfaces only as part of an
abandoned-branch link.

## 5. Table form — discriminator → routing → Entry

| `line.type`   | Discriminator                                | Routing                                | Entry kind on render                 | Source                                                    |
|---------------|----------------------------------------------|----------------------------------------|--------------------------------------|-----------------------------------------------------------|
| (any)         | session-orphan metadata                      | `.skip`                                | —                                    | `CommonLineDispatcher.swift:32`                               |
| `pr-link`     | —                                            | `.renderSpecial(.prLink)`              | `SynthesizedEntry.prLink`            | `CommonLineDispatcher.swift:27`                               |
| (any)         | `isSidechain == true`                        | `.sidechainMain`                       | pooled (parent Task detail tab)      | `ClaudeLineDispatcher.swift:79`                           |
| `user`        | `isCompactSummary == true`                   | `.render(.compact)`                    | `CompactEntry`                       | `UserLineDispatcher.swift:20`                                 |
| `user`        | uuid in `skillCommandUuids`                  | `.render(.user)`                       | `UserEntry` (typed `/cmd args`)      | `UserLineDispatcher.swift:30`                                 |
| `user`        | meta + tool_result block                     | `.render(.agent)`                      | merged into pending `AgentEntry`     | `UserLineDispatcher.swift:64`                                 |
| `user`        | meta + `<command-name>` / `<command-message>` | `.renderSpecial(.slashCmdInput)`      | `SystemEntry.slashCmdInput`          | `UserLineDispatcher.swift:69`                                 |
| `user`        | meta + `<local-command-stdout/stderr>`       | `.renderSpecial(.slashCmdOutput)`      | `SystemEntry.slashCmdOutput`         | `UserLineDispatcher.swift:70`                                 |
| `user`        | meta + `<system-reminder>`                   | `.renderSpecial(.systemReminder)`      | `SystemEntry.systemReminder`         | `UserLineDispatcher.swift:71`                                 |
| `user`        | meta + `Base directory for this skill:`      | `.renderSpecial(.skill)`               | `SystemEntry.skill(name, basePath)`  | `UserLineDispatcher.swift:72`                                 |
| `user`        | meta + `## Context Usage`                    | `.renderSpecial(.contextUsage)`        | `SystemEntry.contextUsage`           | `UserLineDispatcher.swift:73`                                 |
| `user`        | meta + `Continue from where you left off.`   | `.skip`                                | —                                    | `UserLineDispatcher.swift:76`                                 |
| `user`        | meta + `<local-command-caveat>`              | `.skip`                                | —                                    | `UserLineDispatcher.swift:77`                                 |
| `user`        | meta + unknown                               | `.renderSpecial(.unknownMeta)`         | `SystemEntry.systemReminder`         | `UserLineDispatcher.swift:78`                                 |
| `user`        | non-meta plain text                          | `.render(.user)`                       | `UserEntry`                          | `UserLineDispatcher.swift:48`                                 |
| `user`        | non-meta + interrupt prefix                  | (builder) → `.agent`                   | merged into pending `AgentEntry`     | `ClaudeTranscriptBuilder.swift:975`                       |
| `user`        | non-meta + stdout/stderr envelope            | (builder) → `.system`                  | `SystemEntry.localCommand`           | `ClaudeTranscriptBuilder.swift:965`                       |
| `assistant`   | `model == "<synthetic>"`                     | `.skip`                                | —                                    | `AssistantLineDispatcher.swift:20`                            |
| `assistant`   | otherwise                                    | `.render(.agent)`                      | merged into pending `AgentEntry`     | `AssistantLineDispatcher.swift:23`                            |
| `system`      | `subtype == "turn_duration"`                 | `.skip`                                | (read by `ClaudeTurnDurationResolver`) | `SystemLineDispatcher.swift:20`                             |
| `system`      | `subtype == "away_summary"`                  | `.renderSpecial(.recap)`               | `SystemEntry.recap`                  | `SystemLineDispatcher.swift:23`                               |
| `system`      | `subtype == "compact_boundary"`              | `.render(.compact)`                    | `CompactEntry`                       | `SystemLineDispatcher.swift:29`                               |
| `system`      | `subtype == "local_command"` (input)         | `.renderSpecial(.slashCmdInput)`       | `SystemEntry.slashCmdInput`          | `SystemLineDispatcher.swift:45`                               |
| `system`      | `subtype == "local_command"` (output)        | `.renderSpecial(.slashCmdOutput)`      | `SystemEntry.slashCmdOutput`         | `SystemLineDispatcher.swift:53`                               |
| `system`      | other / unknown subtype                      | `.render(.system)`                     | `SystemEntry.localCommand`           | `SystemLineDispatcher.swift:64,71`                            |
| `attachment`  | `type == "queued_command"`, `commandMode == "task-notification"` | `.skip`     | —                                    | `AttachmentLineDispatcher.swift:25`                           |
| `attachment`  | `type == "queued_command"` (otherwise)       | `.renderSpecial(.queuedPrompt)`        | `UserEntry` (queued)                 | `AttachmentLineDispatcher.swift:30`                           |
| `attachment`  | `type == "plan_mode"`                        | `.renderSpecial(.planModeEntered)`     | `SystemEntry.planMode(.entered)`     | `AttachmentLineDispatcher.swift:36`                           |
| `attachment`  | `type == "plan_mode_exit"`                   | `.renderSpecial(.planModeExited)`      | `SystemEntry.planMode(.exited)`      | `AttachmentLineDispatcher.swift:42`                           |
| `attachment`  | `type == "plan_mode_reentry"`                | `.renderSpecial(.planModeReentered)`   | `SystemEntry.planMode(.reentered)`   | `AttachmentLineDispatcher.swift:48`                           |
| `attachment`  | `type == "edited_text_file"`                 | `.renderSpecial(.editedTextFile)`      | `SystemEntry.editedTextFile`         | `AttachmentLineDispatcher.swift:54`                           |
| `attachment`  | other types (hook_success, …)                | `.skip`                                | —                                    | `AttachmentLineDispatcher.swift:60`                           |
| (any)         | `activeBranchAvailable && uuid ∉ activeBranch` | `.skipBranchAffiliated`              | rolled into `SynthesizedEntry.rewind` at divergence point | `ClaudeLineDispatcher.swift:116`         |
| (unknown)     | `type` doesn't match any case                | `.skip` + DEBUG warning                | —                                    | `ClaudeLineDispatcher.swift:110`                          |

## 6. Per-line dispatch (post-G6 — no resolvers)

`ClaudeTranscriptBuilder` runs **zero pre-pass resolvers**. Every JSONL
line stands on its own and either creates an entry, mutates one, pushes
or pops the pending-prompt FIFO, or registers an alias.

`BuildContext` carries 4 fields:

```swift
fileprivate struct BuildContext {
    let logger: any AgentXrayLogger
    var root = Transcript()
    var pendingPromptQueue: [(id: EntryID, text: String)] = []
    var awaitingParent: [String: ClaudeJSONLLine] = [:]
}
```

**Universal alias rule.** `Transcript.index` carries every JSONL line
uuid — either as a real entry id (when the line's own append registers
it) or as an alias mapping to its parent's resolved path (chained
assistant lines, `tool_result` mutators, `turn_duration` mutators,
skipped decorators). Children resolve in O(1) without re-walking the
JSONL chain.

**Out-of-order pool.** A line whose `parentUuid` isn't yet in
`Transcript.index` is parked in `awaitingParent[parentUuid]`. Drain
fires after every successful uuid registration. Single-child invariant
(corpus 0/731 with 2+); DEBUG-asserted.

**Per-line work:**
- **Top-level kinds** (user-typed prompt, system, compact, slashCmdInput,
  recap, prLink, queuedPrompt, planMode, editedTextFile, systemReminder)
  append at top-level regardless of `parentUuid`.
- **Assistant content blocks** (`text` / `thinking` / `tool_use`) fold
  into the AgentEntry resolved via the parent's top-level slot — fresh
  AgentEntry created when the parent is non-`.agent`. Sub-entry ids
  derive from `(line.stableId, blockIndex)`.
- **Mutation kinds** — `tool_result` blocks invoke `ToolResultUpdate.apply`
  via `Transcript.mutate(id: tool_use_id)`. `system.subtype: turn_duration`
  lines short-circuit dispatch and invoke `TurnDurationUpdate.apply`
  via `Transcript.mutate(id: containingAgentEntry.id)`.
- **FIFO** — `queue-operation enqueue` appends a `.pending` UserEntry
  top-level and pushes `(id, text)` onto `pendingPromptQueue`. Both
  `attachment.queued_command` and slash-cmd input lines pop the
  matching head text and slice out the `.pending` UserEntry, replacing
  it with a `.consumed` UserEntry.
- **Skip kinds** (last-prompt, sidechain wholesale, unknown attachments,
  session-orphan metadata) register an alias only.

**Rewind detection** is inline at top-level user-typed prompt arrival:
when the new prompt's `parentUuid` resolves to a top-level slot K with
trailing entries past K, fold the tail into a synthesized
`.rewind` at slot K+1 via `Transcript.branchOff`. Sibling rewinds at
the same divergence point are siblings at top level (each call to
`branchOff` advances the divergence-point's index past the new rewind
so the next slice naturally starts at the live tail past prior siblings).

## 7. Special-case stitching

- **Sidechain (sub-agent) pooling.** Lines with `isSidechain: true`
  short-circuit to `.sidechainMain` and are pooled by `parentToolUseID`
  in a `[String: [Entry]]` map. The parent Task tool's detail tab links
  to the pooled sub-agent transcript. The sub-agent transcript itself
  is built by recursively running the same pipeline over the pooled
  lines.
- **Abandoned-branch synthesis.** When a top-level user prompt's
  `parentUuid` points back at an earlier slot K, the trailing entries
  past K are sliced into a `SynthesizedEntry.rewind`'s `subEntries`
  via `Transcript.branchOff` (inline, not a separate pre-pass). The
  rewind sits at slot K+1 as a top-level peer; the renderer
  inline-expands its abandoned transcript via the same recursive
  `EntryView` used for live entries.
- **Pending-prompt synthesis.** Unconsumed `queue-operation enqueue`
  events become tail-pinned `UserEntry(isQueuedPending: true,
  wasQueued: true)` rows constructed from the resolver's
  `ClaudePendingPrompt` descriptors.
- **Compact-boundary stitching.** `system, subtype: compact_boundary`
  lines have `parentUuid: null` (the tree breaks at the compact event).
  They carry `logicalParentUuid` pointing at the pre-compaction tail;
  `ClaudeBranchResolver` treats `parentUuid ?? logicalParentUuid` as the
  effective parent so the active chain stitches across compactions.

## 8. `<xml-style>` tag conventions

These tag wrappers appear inside `message.content` (or `system.content`,
or `attachment.prompt`) and discriminate sub-classes within a single
line `type`. Detection lives in `Adapters/Claude/ClaudeContentDetector.swift`.

| Tag                          | Where it appears                          | Detected in                                     | Routes to                            |
|------------------------------|-------------------------------------------|-------------------------------------------------|--------------------------------------|
| `<command-name>`             | meta user / system local_command          | `ClaudeContentDetector.classify` `:97`          | `slashCmdInput`                      |
| `<command-message>`          | meta user (skill-flavour)                 | `ClaudeContentDetector.classify` `:97`          | `slashCmdInput` (with skill resolver)|
| `<command-args>`             | adjacent to `<command-name>`              | `ClaudeContentDetector.classify` `:102`         | (parsed for slash args)              |
| `<local-command-stdout>`     | meta user / system local_command          | `ClaudeContentDetector.classify` `:73`          | `slashCmdOutput`                     |
| `<local-command-stderr>`     | meta user / system local_command          | `ClaudeContentDetector.classify` `:79`          | `slashCmdOutput` (style: error)      |
| `<local-command-caveat>`     | meta user                                 | `ClaudeContentDetector.classify` `:86`          | `.skip`                              |
| `<system-reminder>`          | meta user                                 | `ClaudeContentDetector.classify` `:90`          | `systemReminder`                     |
| `<task-notification>`        | inside `attachment.queued_command.prompt` | filtered by `attachment.commandMode`, **not** by tag prefix | `.skip` |

`<task-notification>` is the lone tag that is *not* tag-prefix-detected
because the same content shape appears in legitimate user prompts
(quoting, debugging, etc.). The discriminator is the structured field
`attachment.commandMode == "task-notification"` set by the harness.

## 9. Maintenance guide

When the Claude Code JSONL surface drifts (new line types, new
discriminators, new tag wrappers), update this document **in the same
commit** as the parser change. Stale routing docs lie about what the
shipping code does.

**Adding a new `line.type`:**
1. Add the field(s) needed to decode it to `ClaudeJSONLLine`
   (`Adapters/Claude/Wire/ClaudeJSONLLine.swift`). Decodable synthesis
   handles the JSON; only add `CodingKeys` entries when the JSON name
   differs from the Swift property name.
2. Decide whether the type is metadata-only (extend
   `CommonLineDispatcher.skipTypes` or `directRoutes`) or branches
   internally (write a new `XLineParser` under
   `Adapters/Claude/Dispatchers/`, dispatched by `type` in
   `ClaudeLineDispatcher.route`).
3. Update the **§4 tree** and **§5 table** in this doc.
4. Add a `@Test` to
   `Tests/CmuxAgentXrayTests/Adapters/Claude/Dispatchers/<X>ParserTests.swift`
   exercising the routing decision (decode a sample line, assert the
   `ClaudeLineRouting` value).

**Adding a new `attachment.type`:**
1. Add a case to `AttachmentLineDispatcher.parse`. Default arm is `.skip`,
   so unknown types remain quiet.
2. If renderable, add the matching `ClaudeSpecialKind` case in
   `ClaudeLineDispatcher.swift` and the corresponding emitter arm in
   `ClaudeTranscriptBuilder.emitSpecial`.
3. Update §4 + §5; add an `AttachmentParserTests` case.

**Adding a new `system.subtype`:**
1. Add a case to `SystemLineDispatcher.parse`. The default arm catches
   unknowns as `render(.system)` so nothing disappears silently.
2. Update §4 + §5; add a `SystemParserTests` case.

**Adding a new `<xml-style>` tag wrapper:**
1. Add a `ClaudeMetaContent` case in
   `Adapters/Claude/ClaudeContentDetector.swift`.
2. Add the detection branch in `ClaudeContentDetector.classify`.
3. Route it in `UserLineDispatcher.routingForMetaUser` (and, if the
   `system, subtype: local_command` envelope can also carry it, in
   `SystemLineDispatcher.parse`).
4. Update §8 + §4/§5.

**Adding a new origin discriminator on attachments**
(like `commandMode` was added for `queued_command`):
- **Always blacklist, never allowlist.** Older sessions in the wild
  often emit the field as `null` or omit it; an allowlist (`== "X"`)
  silently drops valid data. The pattern is
  `if line.attachment?.fooMode == "<unwanted-value>" { return .skip }`
  inside the existing arm, before falling through to the normal
  routing.
- Document the value taxonomy you observed (which values exist, which
  surface as user-visible, which are harness-internal). Code review
  needs the table to validate the blacklist set.

**General rules:**
- Per-line tests live in `Tests/CmuxAgentXrayTests/Adapters/Claude/Dispatchers/`
  and exercise `<X>LineParser.parse(...)` directly. Decode JSON via
  `AgentXrayJSON.decoder` so the tests cover the full string-→-value
  path.
- Resolver tests exercise pure-value-function output for a synthetic
  `[ClaudeJSONLLine]` input.
- `ClaudeTranscriptBuilder`-level integration tests exist for the
  emitter side; prefer adding to `EntryTreeTests` only when a routing
  decision genuinely needs end-to-end coverage.

## 10. Out of scope

- **Codex JSONL.** Codex sessions live in
  `~/.codex/sessions/<date-buckets>/` and use a different schema.
  Their adapter is in `Sources/CmuxAgentXray/Adapters/Codex/` and is
  *not* covered by this document.
- **Hook session JSON.** `~/.cmuxterm/{claude,codex}-hook-sessions.json`
  feeds session-attach resolution
  (`Streaming/AgentSessionResolver.swift`), not transcript parsing.
  See `docs/session-attach.md` for that flow.

## 11. Content-block type reference (Phase B/C/E, 2026-06-07)

Canonical mapping of Claude Messages-API content blocks to ``Section``
variants. Compiled from the Anthropic Messages API spec
(`docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview` +
`docs.anthropic.com/en/api/messages`) and verified against the user's
`~/.claude/projects/*/*.jsonl` corpus 2026-06-07 (~700 files).

### `tool_result.content[]` block types

Realistic block types in a Claude Code JSONL transcript (CC uses the
plain Messages API + local-MCP path; managed-tool / connector-beta
blocks never appear here):

| `type`              | Section variant                    | Corpus 2026-06-07          | Producer                           |
|---------------------|------------------------------------|----------------------------|------------------------------------|
| `text`              | `.text([s], style: .normal/.error)` | very common               | every tool                         |
| `image`             | `.image(ImageSource)` (base64)     | 24 blocks / 16 files       | Playwright `browser_take_screenshot` |
| `tool_reference`    | `.toolReference(toolName:)`        | 158 blocks / 67 files      | CC's client-side `ToolSearch`      |
| `redacted_thinking` | `.text(["[type]"], .normal)` stub  | 0 hits past 2026-06-07     | spec-only-not-corpus               |
| `search_result`     | `.text(["[type]"], .normal)` stub  | 0 hits past 2026-06-07     | spec-only-not-corpus               |
| `document`          | `.text(["[type]"], .normal)` stub  | 0 hits past 2026-06-07     | spec-only-not-corpus               |

Stub-rendered types emit `AgentXrayLogger.warning` so future surfacing
is visible in sysdiagnose without re-grepping. The inline comment in
`buildToolResultSections` carries a `VERIFY-CORPUS-2026-06-07` date-cut
reminder; re-grep `~/.claude/projects/*/*.jsonl` modified after that
date if any of these surface in the UI.

Block types in the spec but **not reachable** from CC JSONL (don't
design rich rendering for these unless the path opens up):

- Managed-tool family — `server_tool_use`, `web_search_tool_result`,
  `web_fetch_tool_result`, `code_execution_tool_result`,
  `bash_code_execution_tool_result`,
  `text_editor_code_execution_tool_result`,
  `tool_search_tool_result` (distinct from CC's client `ToolSearch`
  even though both produce `tool_reference` payloads in different
  parents), `container_upload`. Anthropic-platform-emitted for
  Anthropic-hosted tools; CC consumes the Messages API directly and
  never enables them.
- Connector beta — `mcp_tool_use`, `mcp_tool_result`. Only arrive
  when the `anthropic-beta: mcp-client-2025-04-04` header is set on
  `/v1/messages`. CC uses the **local** MCP path; MCP tool calls
  flow through plain `tool_use` / `tool_result` shapes with the
  synthesized `mcp__<server>__<tool>` name as the only discriminator.

### `user.message.content[]` block types

| `type`  | Section variant                 | Corpus 2026-06-07 |
|---------|---------------------------------|-------------------|
| `text`  | `.text([s], style: .normal)`    | the default      |
| `image` | `.image(ImageSource)` (base64)  | 15 files (user-pasted screenshots) |

**Both image parents matter**: `image` blocks appear directly in
top-level `user.message.content[]` (user-pasted) AND inside
`tool_result.content[]` (Playwright screenshots). The same
`Section.image` variant carries both — the builder's
`buildUserContentSections(from:)` and
`buildToolResultSections(_:isError:logger:)` emit it from each parent.

### MCP server identification

JSONL carries **only** the synthesized `mcp__<configured-name>__<tool>`
string. There is no transport, scope, or canonical id on the wire.
Each registered name is treated as a distinct logical server — name
normalization is **not safe** (the same binary can be registered
under multiple names; conversely, two different names can hide
behind the same code path via env vars).

`ClaudeTranscriptBuilder.parseMcpToolName(_:)` strips the prefix and
extracts the bare server + tool. The Phase E shape-sniffer carries
`mcpServer: String?` as a reserved future-hint parameter; no
allow-list today.

### `<persisted-output>` wrapper

CC offloads tool outputs above its inline-size threshold to
`/tmp/.../<id>.txt` or `.json` and inlines a single-text wrapper
referencing the path. Phase C's
`ClaudeTranscriptBuilder.parsePersistedOutput(_:)` detects this and
emits `Section.offloadedOutput(OffloadedOutput)`. Canonical shape:

```
<persisted-output>
Output too large (29.3KB). Full output saved to: /tmp/<dir>/<id>.txt

Preview (first 2KB):
<inline preview>
</persisted-output>
```

Path-extraction regex (validated against 252 corpus occurrences):

```
^Output too large \(([0-9]+(?:\.[0-9]+)?(?:KB|MB))\)\. Full output saved to: (\S+?\.(?:txt|json))$
```

**Robust to truncated tails.** ~21 of 252 corpus occurrences omit the
`</persisted-output>` close tag; detection only requires the open
tag + the canonical "Output too large" line.

### `toolUseResult` envelope (Claude Code extension)

Every `tool_result`-bearing JSONL line on Edit / MultiEdit / Write
(and several other tools) carries a top-level `toolUseResult` field
**alongside** the standard Anthropic `message.content[].tool_result`
shape. This is a Claude-Code-specific extension — not part of the
public Messages API — and it ships exactly the data the TUI uses to
paint Edit rows, on first run *and* on session resume (no filesystem
access, no diff algorithm).

**Polymorphism.** The field's value is **not** uniformly an object.
Corpus survey (415 occurrences in one session): 391 objects, 21 bare
strings (Bash error tails), 3 arrays (Playwright text-block results).
A typed-only `let toolUseResult: ClaudeToolUseResult?` would
`typeMismatch` and silently drop every Bash error / Playwright
result on resume. Wire shape is `ClaudeJSONValue?` (matching
`ClaudeContentBlock.toolResultContent`); typed projection happens at
the builder via `ClaudeToolUseResult.from(_ value: ClaudeJSONValue?)`,
which returns nil for non-object shapes.

Object schema (all fields optional):

| Field | Type | Notes |
|---|---|---|
| `filePath` | `String` | Absolute path of the edited file. |
| `oldString` / `newString` | `String` | Per-edit pre / post text (Edit / MultiEdit). |
| `originalFile` | `String` | Pre-edit snapshot of the *full file*. **Not consumed** by the model — kept on the wire type for a possible future "show pre-edit file" affordance. |
| `userModified` | `Bool` | True when the user manually tweaked the model's edit. |
| `replaceAll` | `Bool` | Edit / MultiEdit replace-all flag. |
| `type` | `String` | Write tool: `"create"` (new file) vs `"update"` (existing). Empty `structuredPatch` on `create`. |
| `structuredPatch` | `[Hunk]` | Per-hunk array — see below. |

### `structuredPatch[]` schema

```jsonc
{
  "oldStart": 17,    // 1-indexed first line in the pre-edit file
  "oldLines": 5,     // # pre-edit lines covered (context + removed)
  "newStart": 17,    // 1-indexed first line in the post-edit file
  "newLines": 6,     // # post-edit lines covered (context + added)
  "lines": [         // pre-prefixed line array, arrival order:
    " context line",
    "-removed line",
    "+added line",
    " context"
  ]
}
```

Each entry in `lines[]` starts with one of `' '` (context), `'-'`
(removed), or `'+'` (added) followed by the line text. Corpus
distribution on a single 93-Edit session (119 hunks): 1050 context,
853 removed, 1362 added, **0** anomalous prefixes.

**Use sites:**

- `ClaudeTranscriptBuilder.attachToolResult(...)` projects the
  envelope and, when `structuredPatch` is non-empty AND the matched
  tool is Edit-shape (`Edit` / `MultiEdit` / `Write` with
  `type == "update"`), swaps `update.resultSections =
  [.diffHunks(hunks)]`. Bash errors / Playwright text-list results /
  nil envelope → factory returns nil → existing parser sections pass
  through.
- `Models/Body.swift` ships `DiffHunk` as the wire-and-model type
  (collapsed from a parallel pair during plan validation). Inline
  rendering: `Views/Sections/DiffHunkView.swift` (line-number gutters
  + per-line bg + 30-row / 3-KiB cap). Detail-tab serialization:
  `DetailContent.serializeUnifiedDiff(hunks:filePath:)` reassembles
  `--- a/...` + `+++ b/...` + `@@ -X,Y +A,B @@` headers + the
  prefix-embedded `lines`, wraps in a ` ```diff ` fence, routes as
  `tool-result.diff.md` so cmux's `MarkdownPanel` + highlight.js
  paints diff coloring.
- `Write.type == "create"` ships `structuredPatch: []`. The
  builder's non-empty guard skips the swap on create; the file
  content travels through the standard `tool_result.content[]` path.
