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

## Pending items — ordered by difficulty (trivial → heavy)

Numbered for cross-reference. Items are independent unless explicitly noted.
Pick trivially-small items first to ship visible wins; tackle heavier items
once you have context on the surrounding code.

### Tier 1 — trivial (≤ 5 minutes each)

#### T1.1. Grep tool icon swap

Change `EntryIcon.tool(named:)` (`Models/EntryIcon.swift`) for the `Grep` case
from `text.magnifyingglass` / `text.magnifyingglass.fill` to
`questionmark.text.page` / `questionmark.text.page.fill`.

User-requested visual polish. One-line diff in the existing switch.

---

### Tier 2 — small (≤ 1 hour each, single concept, no architecture)

These are independent; pick any order.

#### T2.1. MCP tool single-icon mapping

In `Models/EntryIcon.swift`'s `tool(named:)` switch, add a fallback before
the generic-wrench `default` arm:

```swift
default:
    if name.hasPrefix("mcp__") {
        return EntryIcon(
            collapsed: "externaldrive.connected.to.line.below",
            expanded: "externaldrive.connected.to.line.below.fill"
        )
    }
    return EntryIcon(
        collapsed: "wrench.adjustable",
        expanded: "wrench.adjustable.fill"
    )
```

**No per-server differentiation** — user explicitly asked for one MCP icon
across all servers.

#### T2.2. MCP tool name parsing

In `Adapters/Claude/ClaudeTranscriptBuilder.appendToolUse` (or via a small
helper applied before `Header(name: …)` is constructed), strip the
`mcp__<server>__` prefix from the displayed name and surface `<server>`
as a chip / label:

```
input  block.name = "mcp__playwright__browser_navigate"
output Header.name = "browser_navigate"
       chip / label = "playwright"
```

Where to render the chip: pass it through to the `subEntryHeader`'s
existing `extras` view-builder slot (already used by tool's
`subagentType` magenta chip — same pattern, slightly different color).

Built-in tool names (Read, Edit, Bash, etc.) keep their current rendering.

#### T2.3. `summarizeToolInput` priority-list fallback

`Adapters/Claude/ClaudeTranscriptBuilder.swift:1099` — the `default` arm of
the tool-name switch falls through to `input.displayString`, which dumps
every key=value pair (noisy for unhandled tools). Replace with a priority
list:

```swift
default:
    let preferred = ["url", "path", "file_path", "query", "command",
                     "name", "id", "skill", "key"]
    for key in preferred {
        if case .string(let v)? = obj[key] {
            return truncated(v, max: ClaudeRenderConsts.toolSummaryMaxChars)
        }
    }
    return input.displayString  // last-resort fallback
```

Affects every unhandled tool — including MCP and any future built-in.

#### T2.4. `QueuedState` enum (UserEntry boolean pair → 3-case enum)

Replace `UserEntry.wasQueued: Bool` + `UserEntry.isQueuedPending: Bool`
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

#### T2.5. Builder text-extraction unification

Five near-identical paths walking `ClaudeMessageContent` to extract joined
text. Consolidate to one helper `extractText(from: ClaudeMessageContent?) -> String`
and replace each call site:
- `extractQueuedPromptText` (`ClaudeTranscriptBuilder.swift:365`)
- `extractMetaText` (`:376`)
- inline in `buildUserEntry` (`:444`)
- inline in `buildSystemEntry` (`:475`)
- `extractTextContent` (`:1090`)

Saves ~30 lines, removes a real correctness risk (the five impls could
drift apart).

#### T2.6. `buildPendingUserEntry` → wrap `makeUserEntry`

`Adapters/Claude/ClaudeTranscriptBuilder.swift:422` re-implements
`makeUserEntry` in 17 lines with `wasQueued: true, isQueuedPending: true,
promptId: nil` hardcoded. Should be a 4-line wrapper. Same outcome since
the icon picker `wasQueued ? .queuedUser : .user` already lives in
`makeUserEntry`. (After T2.4 lands, `wasQueued: true, isQueuedPending: true`
becomes `queuedState: .pending`.)

#### T2.7. `buildSystemEntry` two arms converging

After T2.5 lands, both `if line.type == "system"` and `else` branches in
`buildSystemEntry` (`:475`) build identical `SystemEntry` shape — only
differing in how text is extracted. Converge to one return statement.

---

### Tier 3 — medium (multi-file, design-level)

#### T3.1. `DetailContent.Kind` → `ContentType` swap

(Was Phase A of plan stage 7b — explicitly deferred from commit `eabac5f5e`.)

Drop `DetailContent.Kind` enum (with payloads like `.toolInput(toolName:)`,
`.toolResult(toolName:isError:)`, `.subagentTranscript(toolName:subagentType:)`,
`.abandonedBranch(rewindIndex:totalRewinds:)`, etc.) and replace with:

```swift
public enum ContentType: Equatable, Sendable {
    case plainText
    case transcript   // .subentries section
    // T5.x adds .markdown, .code, .json, .diff
}
```

Move per-Kind metadata (toolName, isError, etc.) into **direct fields**
on `DetailContent`:
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

#### T3.2. Persisted-output wrapper detection

**High-leverage** — affects every tool with large output (Bash, Read,
Edit, all MCPs).

Claude Code offloads tool outputs above a size threshold to disk and
inlines a stub like:

```
<persisted-output>
Output too large (128.9KB). Full output saved to: <absolute path to .out file>
</persisted-output>
```

The X-ray panel currently renders this stub verbatim.

**⚠️ Verify against the live corpus first.** Sample 5+ recent sessions
that hit the cap and confirm the exact wrapper tags + path-extraction
regex. The format may differ across Claude Code versions.

**Goal:** detect the wrapper, parse the file path, render an "↗ Open
offloaded result" link. On click, read the file and open in the detail
tab.

**Files:** `Adapters/Claude/ClaudeTranscriptBuilder.swift` (detect in
`flattenToolResult` or in a content-classifier pass), `Panel/DetailContent.swift`
(resolver reads the file when a `.bodySection` request targets a section
whose text starts with the wrapper), `Views/AgentEntryView+CappedBody.swift`
(skip the stub-text render and emit a styled "open offloaded" link
instead of the cap-overflow link).

---

### Tier 4 — heavy (model + view changes, larger PRs)

#### T4.1. `Section` richness — `image`, `toolReference`, optionally `resource`

`Section` is currently `.text([String], style: TextStyle) | .subentries([Entry])`.
`tool_result.content` arrays carry block types beyond text:
- `tool_reference` (produced by `ToolSearch`) — silently dropped today.
- `image` (Playwright MCP, image-gen MCPs, computer-use) — silently
  dropped today.
- `resource` (MCP spec) — silently dropped today.

Extend `Section` with new cases:
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
in the corpus today and can be pruned at the same time.

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

1. **Tier 1** (T1.1 — Grep icon) — single commit, ship as warmup.
2. **Tier 2** in any order. Natural bundling:
   - **Bundle A:** T2.1 + T2.2 + T2.3 (MCP polish — single commit; small UI improvement visible immediately).
   - **Bundle B:** T2.4 (QueuedState — pure model refactor, isolated).
   - **Bundle C:** T2.5 + T2.6 + T2.7 (ClaudeTranscriptBuilder dedup train; T2.5 enables T2.7).
3. **Tier 3** — T3.1 next (cleans up the type model before adding more cases via Tier 4); then T3.2 (persisted-output, high-leverage).
4. **Tier 4** — T4.1 (Section richness — unblocks visible rendering for tool_reference + images).
5. **Tier 5** — T5.1 + T5.2 (multi-PR effort; takes the rest of the runway).

This sequencing keeps PRs reviewable (each Tier 1/2/3 item is one
focused change) while building toward the bigger Tier 4/5 features
without a giant flag-day refactor.

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
