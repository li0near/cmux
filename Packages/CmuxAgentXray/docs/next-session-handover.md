# AgentX-ray — pending work handover (2026-06-06)

This doc lists the open items discussed during the 2026-06-05 / 2026-06-06
refactor session that **have not yet landed**. Each entry has a clear
acceptance criterion and a pointer to the relevant file:line.

The session itself landed:
- Sub-entry interleave (`.text` + `.tool` in JSONL arrival order).
- `TimeMarker` + entry-level `timestamp` projection.
- `TextSubEntry` merge.
- `ToolEntry.toolName` → computed.
- `AgentSubEntry` protocol drop.
- Body unification (per-section `TextStyle` + `cappedBody` walker).
- DetailRequest collapse to single `.bodySection`.
- ClaudeTranscriptBuilder dedup (loc helper, makeSystemEntry, makeTextSubEntry, planModeMetadata, appendTextEvent, withResult/withSidechain mutators, single subEntries array).

See `MIGRATION_PLAN.md §14` rows 19a–19f for landed commits.

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

## Pending items

Numbered for cross-reference. Independent unless noted.

### 1. `DetailContent.Kind` → `ContentType` swap (was Phase A of plan stage 7b)

**Status:** explicitly deferred from commit `eabac5f5e`. The DetailRequest
collapse landed; the Kind→ContentType half didn't.

**Goal:** drop `DetailContent.Kind` enum (with payloads like
`.toolInput(toolName:)`, `.toolResult(toolName:isError:)`,
`.subagentTranscript(toolName:subagentType:)`, etc.) and replace with:

```swift
public enum ContentType: Equatable, Sendable {
    case plainText
    case transcript   // .subentries section
    // Phase B cases land later: .markdown, .code, .json, .diff
}
```

Move the per-Kind metadata (`toolName`, `isError`, `subagentType`,
`rewindIndex`, etc.) into **direct fields** on `DetailContent`:
- `title: String` (existing)
- `subtitle: String?` (existing)
- `icon: EntryIcon` (new — was derived from Kind)
- `accent: PaletteRole` (new — was derived from Kind)
- `contentType: ContentType` (new)
- `body: String` / `entries: [Entry]?` (existing)

`TranscriptView.detailKindIcon(for:)` and `detailKindAccent(for:palette:)`
(`Views/TranscriptView.swift:478, 499`) are the only Kind readers.
Migrate them to read the new direct fields. Resolver computes the
direct fields at resolve time from entry context (already does this for
title/subtitle).

**Files:** `Panel/DetailContent.swift`, `Views/TranscriptView.swift`,
plus a new `PaletteRole` enum or use existing `Color`-named keys.

### 2. `QueuedState` enum (UserEntry boolean pair → 3-case enum)

**Goal:** replace `UserEntry.wasQueued: Bool` + `UserEntry.isQueuedPending: Bool`
with `UserEntry.queuedState: QueuedState`:

```swift
public enum QueuedState: Equatable, Sendable {
    case none      // typed-inline regular prompt
    case consumed  // was queued mid-turn, now settled (queued icon, no pulse)
    case pending   // tail-pinned synthetic, awaiting consumer (queued icon + pulse)
}
```

Eliminates the impossible fourth `(wasQueued: false, isQueuedPending: true)`
state. Both readers map trivially:
- `wasQueued` → `state != .none`
- `isQueuedPending` → `state == .pending`

**Files:** `Models/Entries/UserEntry.swift`, `Adapters/Claude/ClaudeTranscriptBuilder.swift`
(3 caller sites: queued slash, queued attachment, pending synthetic),
`Behavior/Visibility/EntriesFilter.swift:125, 210` (the only outside-builder
reader).

### 3. ClaudeTranscriptBuilder remaining audit items (semantic dedup)

From the second audit pass — these are still on the table:

**3a. Text-extraction unification.** Five near-identical paths walking
`ClaudeMessageContent` to extract joined text:
- `extractQueuedPromptText` (`ClaudeTranscriptBuilder.swift:365`)
- `extractMetaText` (`:376`)
- inline in `buildUserEntry` (`:444`)
- inline in `buildSystemEntry` (`:475`)
- `extractTextContent` (`:1090`)

One helper covers all five. Saves ~30 lines, removes a real correctness
risk (the five impls could drift apart).

**3b. `buildPendingUserEntry` → wrap `makeUserEntry`.** Currently 17 lines
re-implementing `makeUserEntry` with `wasQueued: true, isQueuedPending: true,
promptId: nil` hardcoded. Should be a 4-line wrapper. Same outcome since
the icon picker `wasQueued ? .queuedUser : .user` already lives in
`makeUserEntry`.

**3c. `buildSystemEntry` two arms converging.** After 3a lands, both
`if line.type == "system"` and `else` branches build identical SystemEntry
shape — only differing in how text is extracted. Converge to one return
statement.

### 4. `summarizeToolInput` MCP fallback (header summary polish)

**Problem:** `ClaudeTranscriptBuilder.summarizeToolInput` (`:1099`)
special-cases Read/Edit/Write/Bash/Grep/Glob/Task/WebFetch/WebSearch.
Anything else (especially MCP tools like `mcp__playwright__browser_evaluate`)
falls through to `input.displayString`, which dumps every key=value pair —
noisy.

**Goal:** add a smarter default fallback that picks the most "title-shaped"
field from the input dict by priority list:

```swift
let preferred = ["url", "path", "file_path", "query", "command", "name",
                 "id", "skill", "key"]
for key in preferred {
    if case .string(let v)? = obj[key] { return truncated(v, max: ...) }
}
// fallback to input.displayString
```

Affects every unhandled tool — including MCP and any future built-in
Claude Code adds.

### 5. MCP tool name parsing + icon (header polish)

**Goal:** strip `mcp__<server>__` prefix from displayed names. `mcp__playwright__browser_navigate`
becomes:
- `name`: `browser_navigate`
- new chip / label: `playwright` (small magenta-ish or distinct color).

**Icon** for any tool name starting with `mcp__`:
- Use `EntryIcon(collapsed: "externaldrive.connected.to.line.below", expanded: "externaldrive.connected.to.line.below.fill")`. **No per-server differentiation** — user explicitly asked for one MCP icon.

**Also (related polish):** change the `Grep` tool icon from
`text.magnifyingglass` to **`questionmark.text.page`** / `questionmark.text.page.fill`.
User-requested in the same conversation.

**Files:** `Models/EntryIcon.swift` (Grep icon swap + MCP fallback case in
`tool(named:)`), `Adapters/Claude/ClaudeTranscriptBuilder.swift`
(`appendToolUse` derives display name + chip from `block.name`).

### 6. Persisted-output wrapper detection (high-leverage)

**Problem:** Claude Code offloads tool outputs above a size threshold to
disk and inlines a stub like:

```
<persisted-output>
Output too large (128.9KB). Full output saved to: <absolute path to .out file>
</persisted-output>
```

The X-ray panel currently renders this stub verbatim. Affects every
tool with large output (Bash, Read, Edit, all MCPs).

**Verify against corpus first:** the wrapper format may differ across
Claude Code versions. Sample 5+ recent sessions that hit the cap and
confirm the exact wrapper tags + path-extraction regex.

**Goal:** detect the wrapper, parse the file path, render an "↗ Open
offloaded result" link in the body. On click, read the file and open
in the detail tab.

**Files:** `Adapters/Claude/ClaudeTranscriptBuilder.swift` (detect in
`flattenToolResult` or in a content-classifier pass), `Panel/DetailContent.swift`
(resolver reads the file when a `.bodySection` request targets a section
whose text starts with the wrapper), `Views/AgentEntryView+CappedBody.swift`
(skip the stub-text render and emit a styled "open offloaded" link
instead of the cap-overflow link).

### 7. Section richness — `image`, `toolReference`, optionally `resource`

**Problem:** `Section` is currently `.text([String], style: TextStyle) | .subentries([Entry])`.
`tool_result.content` arrays carry block types beyond text:
- `tool_reference` (produced by `ToolSearch`) — silently dropped today.
- `image` (potentially from Playwright MCP, image-gen MCP, computer-use)
  — silently dropped today.
- `resource` (MCP spec) — silently dropped today.

**Goal:** extend `Section` with new cases:
```swift
case toolReference(toolName: String)
case image(source: ImageSource)  // base64 + media type
case resource(uri: String, mimeType: String?)  // MCP resource
```

Inline rendering can be minimal (a chip/badge for `tool_reference`, a
thumbnail for `image`, a link for `resource`); **rich rendering goes to
the detail tab** (per user preference).

**Files:** `Models/Body.swift` (new `Section` cases + `ImageSource`
struct), `Adapters/Claude/ClaudeTranscriptBuilder.swift` (replace
`flattenToolResult`'s text-join with per-block section emission),
`Views/AgentEntryView+CappedBody.swift` and `EntryBodyView.swift`
(handle the new cases inline), detail-tab views (handle in detail mode).

`flattenToolResult`'s `.object` and `default` branches are unreachable
in the corpus and can be pruned at the same time.

### 8. MCP `### Section`-style content split (detail-tab only)

**Problem:** Playwright MCP (and likely other MCPs) returns text blocks
formatted like:

```
### Result
<JSON or text>

### Ran Playwright code
```js
<JS source>
```
```

Today, this is a single capped text block. User wants:
- **Inline:** keep flat (no rich rendering inline).
- **Detail tab:** split on `### <Heading>` boundaries; recognize fenced
  code blocks; render each section per its content type. This is the
  Phase-B-rich-rendering hook (markdown / code-with-syntax-highlight).

**Verify first:** sample 10+ MCP `tool_result` blocks across 3+ servers
to confirm the convention is consistent. Some MCPs may use Markdown
without `###` headings, or use different heading conventions.

**Files:** detail-tab content resolver (`Panel/DetailContent.swift`)
splits the body string on the heading regex; emits a richer DetailContent
that can carry multiple typed sections; detail-tab view renders code
blocks with syntax highlighting (Phase B work — depends on
`ContentType.code` / `.markdown` cases from item 1).

### 9. Phase B — rich detail-tab rendering

**Goal:** add `ContentType` cases for `.markdown / .code(language:) / .json
/ .diff`. Builders annotate each section's content type. Detail tab
renders per type:
- `.markdown` → markdown parser
- `.code(language: "js")` → syntax highlighter
- `.json` → pretty-printed JSON
- `.diff` → unified diff view

Each renderer is its own focused PR; the foundation (the ContentType
enum + Section.text(_, style:, contentType:) third-axis) lands first.

Was the original "Phase B" in the refactor plan, explicitly deferred.

---

## Suggested commit groupings

Smallest visible win to land first:
- **A.** Items 4 + 5 (summary fallback + MCP icon + Grep icon swap).
  ~1 commit, small, immediate UI improvement.
- **B.** Item 2 (QueuedState enum). ~1 commit, pure refactor cleanup.
- **C.** Items 3a + 3b + 3c (remaining ClaudeTranscriptBuilder dedup).
  ~1 commit, ~80 lines down.
- **D.** Item 1 (Kind → ContentType). ~1 commit, medium scope.
- **E.** Item 6 (persisted-output handling). High leverage, own focused PR.
- **F.** Item 7 (Section richness for image / tool_reference / resource).
  Larger PR; touches Models + Views.
- **G.** Items 8 + 9 (rich detail-tab rendering, Phase B). Multi-PR effort.

A → B → C → D forms a tight refactor train. E and F are independent
features; F unblocks visible improvements (image / tool_reference now
render). G is the longest-tail.

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
| `MIGRATION_PLAN.md` | Phase log + bug-fix ledger + deferred-task ledger. §14 rows 19a–19f log this session's work. |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (parser tree + table + maintenance guide). |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH attach, RemoteSessionStore). |
| `docs/next-session-handover.md` | **(this doc)** Pending work + verification reminders. |

If any doc disagrees with the code, the code wins — fix the doc in the same change.
