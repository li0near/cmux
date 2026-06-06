# CmuxAgentXray

Self-contained Swift package providing the **AgentX-ray** feature for cmux: a
side-by-side companion panel that mirrors the Claude Code or Codex session
running in the workspace's currently focused terminal.

This package is a fork-side feature in `manaflow-ai/cmux`.

## What it does

- Live-tails the active agent's JSONL transcript file (Claude Code or Codex).
- Builds a typed `Transcript = [Entry]` model from raw JSONL lines.
- Renders a streaming, expandable list of entries in a SwiftUI panel.
- Supports two scroll modes: **free** (whole transcript) and **snap**
  (filtered to the turn(s) currently visible in the paired terminal viewport).
- Surfaces hidden information (model version, token usage, thinking blocks,
  tool I/O, sub-agent transcripts) via per-row expand/collapse.
- Routes overflow content to a sibling **Detail** tab in the same workspace pane.

## Architecture (data flow)

```
JSONL file
  → Streaming        (file watch, line stream, session resolution)
  → Adapters         (Claude / Codex transcript builders)
  → Models           (Entry tree: Entry { Header + Body })
  → Behavior         (expansion / visibility / anchors / bulk actions)
  → Snapshots        (immutable view-input DTOs)
  → Views            (LazyVStack rendering)
  → Panel            (@Observable ViewModel — AgentXrayPanel)
  ⇄  Host            (cmux app integration via AgentXrayHost protocol)
```

### Parser reference

How each Claude JSONL line type / subtype / `<xml-style>` wrapper /
attachment discriminator maps to a `ClaudeLineRouting` value and an
`Entry` — tree form, table form, and the maintenance guide for adding
new branches — lives in
**[`docs/claude-jsonl-mapping.md`](docs/claude-jsonl-mapping.md)**.

## Vocabulary

- **Entry** — umbrella enum for every transcript item. Five top-level cases:
  `user`, `agent`, `system`, `compact`, `synthesized`.
- **Transcript** — a `[Entry]` document.
- **AgentEntry** — the only container Entry; carries `subEntries: [SubEntry]`
  where `SubEntry` is one of `text(TextSubEntry)` or `tool(ToolEntry)`.
  `TextSubEntry` covers both thinking and final assistant text via its
  `kind: .thinking | .assistant` discriminator. These two cases only ever
  appear inside an AgentEntry.
- **Header** — every Entry's display contract: `icon + name + label + title
  + trailing + timeMarker`. Replaces the older `name`/`summary`/per-row
  `icon` scatter. `timeMarker` is a `.clock(Date)` (top-level rows) or
  `.duration(Int)` (tool sub-rows).
- **Body** — every Entry's content: `sections: [Section]` where
  `Section = .text([String], style: TextStyle) | .subentries([Entry])`. An
  empty `sections` array means "header-only" (Variant A).

The names `Row` and `Chunk` are deliberately absent in this package — they
pulled toward "single line" vs "multi-line" mental models that didn't fit
the actual variable-height entry semantics.

## Layer map

```
Sources/CmuxAgentXray/
├── Models/                            # Pure value types
├── Streaming/                         # JSONL tail + transcript stream + session resolver
├── Adapters/{Claude,Codex}/           # Per-agent transcript builders
├── Behavior/{Expansion,Visibility,Anchors}/  # State machines & policies
├── Views/                             # SwiftUI views + snapshots + helpers
├── Panel/                             # @Observable ViewModel
├── Host/                              # Host protocol surface
└── Resources/Localizable.xcstrings    # English-only
```

## Host integration

The cmux app conforms `Workspace` to `AgentXrayHost` in
`Sources/Panels/AgentXray/Workspace+AgentXray.swift` (app target). The package
never imports cmux types. See `Sources/CmuxAgentXray/Host/AgentXrayHost.swift`
for the protocol surface.

## Session attach resolution

How AgentX-ray decides which Claude/Codex session is running in the
focused terminal and streams its transcript. See
**[`docs/session-attach.md`](docs/session-attach.md)** for the full
flow diagrams, three resolution paths, the Phase-18 hook-before-first-
prompt fix, remote-`$HOME` resolution, `RemoteSessionStore`, the
ControlPath piggyback, per-tab SSH inference, and failure modes.

## Build and test

```bash
# Standalone build
swift build --package-path Packages/CmuxAgentXray

# Standalone tests
swift test  --package-path Packages/CmuxAgentXray

# Build the whole cmux Debug app (links the package)
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agentxray --launch
```

## Status

This package landed in cmux on **2026-06-04**. **All migration phases
are complete** — phases 1–15 plus 17pre / 17a / 17b / 17c / 17d. Every
parity row across the 5 groups (Group 1 behavioural correctness,
Group 2 visual parity, Group 3 per-row layout, Group 4 detail-mode
chrome, Group 5 polish) shipped ✅; Phase 12 (AsyncStream focus
pipeline) closed via 17d.

**Current state:** dogfood iterations + a structural refactor pass
(2026-06-05 → 2026-06-06, phases 19a–19f) landed on top of the migration
commits. Highlights of the refactor:
- Sub-entries now interleave (`.text` + `.tool` in JSONL arrival
  order — preserves the "narrate → tool → narrate → tool" flow).
- `TimeMarker` collapses `Header.timestamp` + `TrailingItem.duration`.
- `TextSubEntry { kind: .thinking | .assistant }` replaces
  `ThinkingEntry` + `AssistantTextEntry`.
- DetailRequest collapses to single `.bodySection(targetID:sectionIndex:)`.
- Body rendering unified through one `cappedBody` walker.

See `MIGRATION_PLAN.md` §14 rows 19a–19f for commits.

**Pending work** is tracked in
[`docs/next-session-handover.md`](docs/next-session-handover.md). Open
items include: `DetailContent.Kind` → `ContentType` swap, `QueuedState`
enum, `summarizeToolInput` MCP fallback, persisted-output wrapper
detection, `Section` richness for image / tool_reference / resource
blocks, and Phase B rich detail-tab rendering.

**Deferred-by-policy items** still tracked in `MIGRATION_PLAN.md` §16:
- A. TextStyle diff cases (speculative future feature)
- B. Inline sub-agent transcript rendering (future UX evolution)
- C. ToolEntry shape evolution (speculative)
- G. xcstrings → .strings SPM build-time pre-compile (no current
     test consumer needs the localized lookup output)

These stay deferred per CLAUDE.md "don't pre-solve hypothetical
future requirements" — none block current functionality.

**For the next session resuming this work, read in this order:**

1. `MIGRATION_PLAN.md` (sibling file) — full phase plan, status table
   (§1), progress log (§14), bug-fix ledger (§15), deferred-task
   ledger (§16), origin cross-reference (§18).
2. `FORK_NOTES.md` (sibling file) — upstream-touch surface ledger;
   update on any fork-side edit outside the package.
3. `Sources/Panels/AgentXray/README.md` — cmux-app-target adapter
   seam; how the package mounts into the host app.

The `AttachStage` feature (status-bar attach-progress labels) and the
behavioural-correctness batch (`scrollForFilter`,
`InspectorRowAnchorsKey`, bulk-action handlers, etc.) shipped on top
of the visual-parity commit — see plan §1 rows 17a/17b/17c.

## Conventions (must read)

- macOS 15 platform floor. No fallback paths.
- English-only localization. New keys ship with `localizations: {}`.
- Snapshot-boundary policy: row views below `LazyVStack` hold zero observable
  references — value snapshots and stable closures only.
- Swift 6 language mode. `ExistentialAny` and `InternalImportsByDefault` upcoming
  features both enabled.
- `View` suffix on SwiftUI views. No `Model` suffix on data types.
- `@Observable` for the panel ViewModel.
- Tests live in `Tests/CmuxAgentXrayTests/`. They do NOT require any
  `cmux.xcodeproj/project.pbxproj` wiring.
