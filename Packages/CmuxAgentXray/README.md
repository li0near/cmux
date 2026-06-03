# CmuxAgentXray

Self-contained Swift package providing the **AgentX-ray** feature for cmux: a
side-by-side companion panel that mirrors the Claude Code or Codex session
running in the workspace's currently focused terminal.

This package is a fork-side feature in `manaflow-ai/cmux`. It evolved from the
spike branch `agent-inspector-swiftui-spike` (whose final state is preserved as
historical reference); the production form lives here.

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

## Vocabulary

- **Entry** — umbrella enum for every transcript item. Five top-level cases:
  `user`, `agent`, `system`, `compact`, `synthesized`.
- **Transcript** — a `[Entry]` document.
- **AgentTurn** — the only container Entry; carries `subEntries: [SubEntry]`
  where `SubEntry` is one of `thinking`, `tool`, `assistantText`. These three
  types only ever appear inside an AgentTurn.
- **Header** — every Entry's display contract: `name + label + title +
  trailing + timestamp + icon`. Replaces the older `name`/`summary`/per-row
  `icon` scatter.
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

This package is mid-migration as of 2026-06-04. Phase status, open work,
and bug-fix ledger live in `~/.claude/plans/agentxray-migration-2026-06-04.md`.
Upstream-touch surface is tracked in `FORK_NOTES.md` (sibling file).

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
