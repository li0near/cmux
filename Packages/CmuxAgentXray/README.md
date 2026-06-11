# CmuxAgentXray

Self-contained Swift package providing the **AgentX-ray** feature for cmux: a
side-by-side companion panel that mirrors the Claude Code or Codex session
running in the workspace's currently focused terminal.

This package is a fork-side feature in `manaflow-ai/cmux`.

## What it does

- Live-tails the active agent's JSONL transcript file (Claude Code or Codex).
- Builds a typed `Transcript` model from raw JSONL lines.
- Renders a streaming, expandable list of entries in a SwiftUI panel.
- Supports two scroll modes: **free** (whole transcript) and **snap**
  (filtered to the turn(s) currently visible in the paired terminal viewport).
- Surfaces hidden information (model version, token usage, thinking blocks,
  tool I/O) via per-row expand/collapse.
- Renders rewinds (abandoned branches) inline, expanded into the live tree.
- Routes overflow content to a sibling **Detail** tab in the same workspace pane.

## Architecture (data flow)

```
JSONL file
  → Streaming        (file watch, line stream, session resolution)
  → Adapters         (Claude / Codex transcript builders)
  → Models           (Transcript + Entry tree)
  → Behavior         (expansion / visibility / anchors / bulk actions)
  → Snapshots        (immutable view-input DTOs)
  → Views            (single recursive EntryView in a LazyVStack)
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

- **Entry** — umbrella enum with 7 cases:
  - **Top-level kinds**: `.user(UserEntry)`, `.agent(AgentEntry)`,
    `.system(SystemEntry)`, `.compact(CompactEntry)`,
    `.synthesized(SynthesizedEntry)`. These appear in
    `Transcript.entries`.
  - **Sub-entry kinds**: `.text(TextSubEntry)`, `.tool(ToolEntry)`. These
    only appear nested inside an `AgentEntry.subEntries`. The builder
    enforces this; a runtime assert in `Transcript.append(parent:entry:)`
    catches regressions.
  - `TextSubEntry` covers both thinking and final assistant text via its
    `kind: .thinking | .assistant` discriminator.
- **Container Entries** — kinds that carry `subEntries: [Entry]`:
  - `AgentEntry.subEntries` — the agent turn's `.text` / `.tool` content
    in JSONL arrival order.
  - `SynthesizedEntry.subEntries` — when `.kind == .rewind(rootUuid:)`,
    holds the abandoned-branch transcript inline (a slice of the
    pre-rewind tree).
- **Transcript** — the document. Holds `entries: [Entry]` (top-level
  list) plus a flat `[EntryID: [Int]]` index keyed by every JSONL line
  uuid for O(depth) lookup at any nesting depth. Mutation API:
  `append(parent:entry:)`, `mutate(id:_:)`, `slice(from:length:replacingWith:)`.
  `branchOff(at:link:)` is a thin wrapper over `slice` for rewind folding.
- **Header** — every Entry's display contract:
  `icon + name + label + title + trailing + timeMarker`. `timeMarker` is
  `.clock(Date)` (most rows) or `.duration(Int)` (tool rows after the
  `tool_result` lands).
- **Body** — every Entry's content: `sections: [Section]`. An empty
  `sections` array means a header-only entry. Section variants:
  `.text([String], style: TextStyle)`, `.image(ImageSource)`,
  `.toolReference(toolName: String)`, `.offloadedOutput(OffloadedOutput)`,
  `.code(CodeContent)` (where `CodeContent = .plain(text:, lineNumberStart:)`
  or `.diff(hunks: [DiffHunk])`). Nested children live on
  `Entry.subEntries`, never in `body.sections`.

## Rendering shape

A single recursive `EntryView` renders every Entry kind at every depth.

- One typography (`Theme.Entry`) and one icon column width
  (`Theme.Metric.entryIconWidth = 14pt`) for every level.
- Indent is depth-multiplied: `depth * Theme.Indent.unit` (= 22pt per
  level) applied to the entry's leading padding.
- First-level emphasis is name **weight** only — driven by
  `Entry.isEmphasized` (returns `true` for top-level kinds, `false` for
  `.text` / `.tool`). Adding / removing emphasized kinds is a one-line
  edit in `Views/Entry+Emphasis.swift`.
- Per-kind accent color comes from `PaletteRole.forEntry(_:)`.
- Expanded containers draw a vertical gutter at the parent's icon
  column (`GutterRail` private struct in `EntryView.swift`); click the
  rail to collapse the parent.
- Abandoned-branch sub-trees render dimmed via `HudPalette.dimmed`
  propagation through the recursion — palette swap, not `.opacity()`,
  so nesting is idempotent (nested rewinds compose without compounding).

## Layer map

```
Sources/CmuxAgentXray/
├── Models/                            # Pure value types (Entry, Transcript, Body, …)
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
flow diagrams, three resolution paths, the hook-before-first-prompt
fix, remote-`$HOME` resolution, `RemoteSessionStore`, the
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

## Pending work

Live list in `MIGRATION_PLAN.md` §16 (deferred-by-policy ledger). Notable
items still genuinely pending:

1. **Sub-agent-as-AgentEntry surfacing** — Task / Agent tool transcripts
   resolve via the universal alias rule but don't yet surface as
   top-level `AgentEntry` rows. (`MIGRATION_PLAN.md` §16.B.)
2. **System / compact image drop (audit S3)** — `buildSystemEntry` and
   `buildCompactEntry` project to `String` via the Wire layer's
   `allText()`, dropping image blocks. Corpus has 0 hits today; the
   fix is to project to `[Section]` like user/assistant entries do.
3. **Async `DetailContent.resolve(...)`** — the offloaded-output read is
   sync today (`String(contentsOf:)`); gated on a broader resolver-
   pipeline async refactor. (§16.O.)
4. **E2E framework** — Layer 1/2/2.5/2.6 design lives at
   `docs/e2e-framework-handover.md`; not yet implemented.
5. **Codex adapter migration** to the post-G6 streaming-dispatch model.
   The Claude adapter is on it; the Codex adapter still uses the
   pre-G6 multi-pass shape. (`MIGRATION_PLAN.md` §16.L.)

## For the next session

Read in this order:

1. `MIGRATION_PLAN.md` (sibling file) — phase log (§14), bug-fix ledger
   (§15), deferred-task ledger (§16), open questions resolved (§17),
   origin cross-reference (§18).
2. `FORK_NOTES.md` (sibling file) — upstream-touch surface ledger;
   update on any fork-side edit outside the package.
3. `docs/claude-jsonl-mapping.md` — canonical content-block type
   reference.
4. `Sources/Panels/AgentXray/README.md` — cmux-app-target adapter seam.

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
