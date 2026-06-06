# AgentX-ray — pending work handover (2026-06-06)

This doc lists the open items discussed during the 2026-06-05 / 2026-06-06
refactor session that **have not yet landed**. Each entry has a clear
acceptance criterion and a pointer to the relevant file:line.

The 2026-06-05/06 sessions landed:
- Sub-entry interleave (`.text` + `.tool` in JSONL arrival order).
- `TimeMarker` + entry-level `timestamp` projection.
- `TextSubEntry` merge.
- `ToolEntry.toolName` → computed.
- `AgentSubEntry` protocol drop.
- Body unification (per-section `TextStyle` + `cappedBody` walker).
- DetailRequest collapse to single `.bodySection`.
- ClaudeTranscriptBuilder dedup (loc helper, makeSystemEntry, makeTextSubEntry, planModeMetadata, appendTextEvent, withResult/withSidechain mutators, single subEntries array).
- **Tier 1 + Tier 2** of this doc (T1.1, T2.1–T2.7).
- **Visual-polish pass:** Theme `summary` → `title` rename, sub-row title
  font regression fix + 11.5pt re-sizing, opacity removed from sub-row
  title, sub-row meta bumped to 10.5pt, eight tool-icon picks (Edit,
  Grep, Bash, WebSearch, Todo*/Task*, plan-mode glyphs), MCP server
  surfaced in the primary name slot with the bare tool name in a new
  `label` slot.

See `MIGRATION_PLAN.md §14` rows 19a–19i for landed commits.

**Latest tip (2026-06-06):** `56ad077ba`. Baseline check before
resuming:
```bash
git log -1 --oneline                             # → 56ad077ba
swift test --package-path Packages/CmuxAgentXray # → 73 tests / 13 suites green
```

## ⚠️ Cross-verification reminder for the next agent

Some of the items below depend on JSONL shapes the corpus may not fully
exercise. **Before claiming any of these "done", grep the user's actual
JSONL corpus** (`~/.claude/projects/*/*.jsonl` — 739 files at audit time)
for the relevant content shapes and verify your assumptions empirically.
Do not trust this doc's empirical claims without re-checking — the corpus
grows daily and shapes drift.

Particularly fragile claims to re-verify:
- "Image content blocks haven't appeared in the corpus" — was true at
  audit time but the user has Playwright MCP configured; new sessions
  will exercise it.
- "tool_reference blocks come from `ToolSearch`" — true at audit time;
  could be expanded by future Claude Code versions.
- "MCP `tool_result.content` follows `### Result\n...\n### Ran <X> code\n...`
  convention" — verified for Playwright MCP only; other MCP servers may
  use different structured-markdown layouts (or none).

The `web-access` skill + Anthropic Messages API docs
(`docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview`) and the
MCP spec (`modelcontextprotocol.io/specification/2025-06-18`) are the
authoritative external references.

---

## Pending items — ordered by difficulty (trivial → heavy)

Numbered for cross-reference. Items are independent unless explicitly noted.
Pick trivially-small items first to ship visible wins; tackle heavier items
once you have context on the surrounding code.

### Tier 1 — trivial (≤ 5 minutes each)

_(All Tier 1 items have shipped — see `MIGRATION_PLAN.md` §14 for commit refs.)_

---

### Tier 2 — small (≤ 1 hour each, single concept, no architecture)

These are independent; pick any order.

#### T2.1. ~~MCP tool single-icon mapping~~ **(landed)**

#### T2.2. ~~MCP tool name parsing~~ **(landed)**

Strip `mcp__<server>__` prefix from `Header.name`; surface `<server>` as a
cyan chip in the sub-row header (alongside the existing magenta
`subagentType` chip). `ToolEntry.mcpServer: String?` carries it.

#### T2.3. ~~`summarizeToolInput` priority-list fallback~~ **(landed)**

#### T2.4. ~~`QueuedState` enum (UserEntry boolean pair → 3-case enum)~~ **(landed)**

#### T2.5. ~~Builder text-extraction unification~~ **(landed)**

#### T2.6. ~~`buildPendingUserEntry` → wrap `makeUserEntry`~~ **(landed)**

#### T2.7. ~~`buildSystemEntry` two arms converging~~ **(landed)**

---

### Tier 3 — medium (multi-file, design-level)

#### T3.1. ~~`DetailContent.Kind` → `ContentType` swap~~ **(landed)**

Phase A of the 2026-06-07 refactor. `DetailContent.Kind` (11 cases) dropped;
direct fields `icon: EntryIcon`, `accent: PaletteRole`, `contentType: ContentType`
populated by each resolver arm. New types: `Models/PaletteRole.swift`,
`Panel/ContentType.swift`. New extension: `HudPalette.color(for:)`.
`TranscriptView.detailKindIcon(for:)` + `detailKindAccent(for:palette:)`
deleted; the detail-mode header reads direct fields.

#### T3.2. ~~Persisted-output wrapper detection~~ **(landed)**

Phase C of the 2026-06-07 refactor. Two-commit regression pattern (C.1
RED → C.2 GREEN). New `Section.offloadedOutput(OffloadedOutput)` variant
+ `Models/OffloadedOutput.swift` value type carrying (path, sizeLabel,
preview). `ClaudeTranscriptBuilder` walks every `.text` section in
`buildToolResultSections` and replaces any matching the canonical
`<persisted-output>` wrapper with `.offloadedOutput`. Robust to truncated
tails (~21 of 252 corpus occurrences omit the close tag). Detail-tab
resolver reads the offloaded file at click time; fallback to a localized
error + the inline preview when the file is unreachable.

---

### Tier 4 — heavy (model + view changes, larger PRs)

#### T4.1. ~~`Section` richness — `image`, `toolReference`~~ **(landed)**

Phase B of the 2026-06-07 refactor. `Section` extended from 2 cases to 4:
- `.text([String], style: TextStyle)` — unchanged
- `.image(ImageSource)` — NEW. User-paste **and** tool-returned share
  one variant. Base64 lazy-decoded off-main at render time
  (`ImageThumbnailView` with `Task.detached`).
- `.toolReference(toolName: String)` — NEW. CC's client-side
  `ToolSearch` deferred-loader emits these in `tool_result.content[]`
  (158 corpus hits / 67 files). `ToolReferenceChipView` renders as
  inline pill with cyan MCP-server chip.
- `.subentries([Entry])` — unchanged.

`resource` deferred — 0 corpus, 0 spec hits in CC's local-MCP path
(MCP→Messages bridge downcasts to text/image at the spec level).

`flattenToolResult` rewritten as `buildToolResultSections(_:isError:logger:)`
emitting one Section per `tool_result.content[]` block. Per-block
mapping covers text, image (base64), tool_reference, plus stub
fallbacks for spec-only-not-corpus types (`redacted_thinking` /
`search_result` / `document`) with `AgentXrayLogger.warning`
emission so future surfacing is detectable in sysdiagnose.

User-paste image path also fixed (`buildUserContentSections(from:)`
walks `user.message.content[]` blocks, emits per-block Sections).
Assistant-emitted image blocks (spec-only-not-corpus) drop with a
warning log instead of the legacy `[image]` placeholder.

`buildPendingUserEntry` vestige inlined at its single call site +
deleted.

---

### Tier 5 — feature work (multi-PR, depends on T3 / T4)

#### T5.1. MCP `### Section`-style content split (detail-tab only)

Playwright MCP (and likely other MCPs) returns text blocks formatted like:

```
### Result
<JSON or text>

### Ran Playwright code
```js
<JS source>
```
```

Today, this is a single capped text block. **Inline rendering stays
flat** (per user preference); the **detail tab** splits on `### <Heading>`
boundaries, recognizes fenced code blocks, and renders each section per
its content type. Hooks into T5.2's rich renderers.

**⚠️ Verify against the live corpus first.** Sample 10+ MCP `tool_result`
blocks across 3+ servers to confirm the convention is consistent. Some
MCPs may use Markdown without `###` headings, or different conventions.

**Files:** detail-tab content resolver (`Panel/DetailContent.swift`)
splits the body string on the heading regex; emits a richer DetailContent
that can carry multiple typed sections; detail-tab view renders per
content type.

#### T5.2. Phase B — rich detail-tab rendering

Add `ContentType` cases for `.markdown / .code(language:) / .json / .diff`.
Builders annotate each section's content type. Detail tab renders per
type:
- `.markdown` → markdown parser
- `.code(language: "js")` → syntax highlighter
- `.json` → pretty-printed JSON
- `.diff` → unified diff view

Each renderer is its own focused PR; the foundation
(`ContentType` enum extension + `Section.text(_, style:, contentType:)`
third axis) lands first.

Was the original "Phase B" in the refactor plan, explicitly deferred.

---

## Suggested execution order

Tiers 1 and 2 are landed (commits `572f65513`, `175cd6a80`, `476db75da`,
`63a787196`). Resume at:

1. **Tier 3** — T3.1 next (cleans up the type model before adding more cases via Tier 4); then T3.2 (persisted-output, high-leverage).
2. **Tier 4** — T4.1 (Section richness — unblocks visible rendering for tool_reference + images).
3. **Tier 5** — T5.1 + T5.2 (multi-PR effort; takes the rest of the runway).

This sequencing keeps PRs reviewable (each Tier 3 item is one focused
change) while building toward the bigger Tier 4/5 features without a
giant flag-day refactor.

---

## How to verify a session is current

Before starting work:

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline                           # confirm tip
swift test --package-path Packages/CmuxAgentXray  # green baseline
```

Should be 73 tests in 13 suites, all green, as of 2026-06-06.

For UI verification:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agentxray --launch
```

---

## Cross-doc map

| Doc | What it covers |
|-----|----------------|
| `README.md` | Package overview, vocabulary, layer map, host integration. Updated this session for `TextSubEntry` + `TimeMarker` vocab. |
| `MIGRATION_PLAN.md` | Phase log + bug-fix ledger + deferred-task ledger. §14 rows 19a–19i log this session's work. |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (parser tree + table + maintenance guide). |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH attach, RemoteSessionStore). |
| `docs/next-session-handover.md` | **(this doc)** Pending work + verification reminders. |

If any doc disagrees with the code, the code wins — fix the doc in the same change.
