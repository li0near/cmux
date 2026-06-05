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

## Vocabulary

- **Entry** — umbrella enum for every transcript item. Five top-level cases:
  `user`, `agent`, `system`, `compact`, `synthesized`.
- **Transcript** — a `[Entry]` document.
- **AgentEntry** — the only container Entry; carries `subEntries: [SubEntry]`
  where `SubEntry` is one of `thinking`, `tool`, `assistantText`. These three
  types only ever appear inside an AgentEntry.
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

## Session attach resolution

`AgentSessionResolver` (`Sources/CmuxAgentXray/Streaming/AgentSessionResolver.swift`)
answers a single question on every focus event: **which Claude/Codex session
is running in the currently focused terminal panel?** The answer joins two
pieces of state cmux already maintains as authoritative — no host-process-tree
scanning, no on-disk heuristics, no argv scraping.

### Resolution flow

```
focus event (debounced 150 ms)
        │
        ▼
┌──────────────────────────┐
│ resolver.resolve(panel)  │
└────────────┬─────────────┘
             ▼
   ╔═══ Path 1: restored snapshot ═══╗
   ║ restoredAgentSnapshot(panelID)? ║
   ╚════════╤══════════════════╤═════╝
            ▼ found            ▼ nil
   build claude transcript     │
   path from (cwd, sid);       │
   return synthesized          │
   ResolvedAgentSession        ▼
                     ╔═══ Path 2: live PID + hook ═══╗
                     ║ for pid in agentPIDs(panelID):║
                     ║   findAgentHookRecord(pid)?   ║
                     ╚═════╤═══════════════════╤═════╝
                           ▼ match             ▼ none
                  return synthesized           │
                  ResolvedAgentSession         ▼
                  (sessionID + transcriptPath  nil
                  from hook record)          (Detached)
```

| # | Path | Source-of-truth | Handles |
|---|---|---|---|
| 1 | Restored snapshot | `Workspace.restoredAgentSnapshotsByPanelId[panelID]` — cmux's session-restoration index, pre-mapped onto the fresh panel UUID | Auto-resume after cmux restart, before agent has spawned or its hook has fired |
| 2 | Live PID + hook record | (a) `CmuxTopProcessSnapshot.captureCached(...).pids(forCMUXSurfaceID:)` reading `CMUX_SURFACE_ID` env vars set by `applyManagedCmuxContextEnvironment` at shell spawn; (b) `~/.cmuxterm/{claude,codex}-hook-sessions.json` joined by PID | Fresh panels post-boot, `/new` mid-session (hook record upserts; live record beats stale snapshot) |

Path 1's transcript path may not exist on disk yet — `JSONLTail` handles
missing files via exponential-backoff open retries and starts streaming the
moment the agent creates it. Codex restoration leaves `transcriptPath` nil
(date-bucketed layout requires extra info).

### Auto-resume timeline

```
cmux restart   shell spawned   agent spawned   SessionStart
                (env injected)  (--resume id)   hook fires
     │                │               │              │
     │           [Path 1 hits ─────────────────▶]    │
     │                │               │              │
     │                │           [Path 2 hits ─────▶]
     ▼                ▼               ▼              ▼
   t=0           ~few-100 ms       ~few-100 ms     ~1 s
```

Path 1 attaches the panel before the agent process exists; Path 2 takes
over once the hook record is on disk and reflects every subsequent
`/new`-style session change.

### Stable across cmux restart

Both sources deliberately survive cmux app restart: the hook store is a JSON
file on disk; the restored-snapshot index rebuilds from cmux's session
snapshot. Volatile signals deliberately **not used** as load-bearing:
`Workspace.id` / `Panel.id` UUIDs (freshly minted on every launch),
`Workspace.agentPIDs` registry (in-memory; only populated by `set_agent_pid`
during `SessionStart`, empty for surviving processes after restart),
per-record `(workspaceId, surfaceId)` hook-store keys (stale post-restart).

### Failure modes

- Hook hasn't fired yet → path 2 returns nil briefly; resolves on next event.
- Hook handler misconfigured → panel stays detached. We don't fabricate a
  session we can't prove exists.
- Two agents in one panel → first PID with a hook record wins (same
  behaviour as cmux's own panel-PID registry).

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
are complete** — phases 1–15 plus 17pre / 17a / 17b / 17c / 17d. The
parity punch-list (`PARITY_PUNCH_LIST.md`) is fully ✅ closed across
its 5 groups (Group 1 behavioural correctness, Group 2 visual parity,
Group 3 per-row layout, Group 4 detail-mode chrome, Group 5 polish).
Phase 12 (AsyncStream focus pipeline) closed via 17d.

**Current state:** dogfood iterations against the spike-parity bar
landed on top of the migration commits — see `git log` on the
`agentxray` branch for `Dogfood pass` commits and the audit-pass
fixes that followed.

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
2. `PARITY_PUNCH_LIST.md` (sibling file) — canonical 87-finding
   checklist of every behavioural / visual gap. All ✅ closed.
3. `VISUAL_PASS_REVIEW.md` (sibling file) — historical user-signed-off
   spec for the visual-parity commit (icons, `Theme.swift` tokens,
   `HoverHighlight` modifier, file moves, renames). Reflects landed
   state.

Upstream-touch surface is tracked in `FORK_NOTES.md` (sibling file).
The `AttachStage` feature (status-bar attach-progress labels) and the
behavioural-correctness batch (`scrollForFilter`,
`InspectorRowAnchorsKey`, bulk-action handlers, etc.) follow the
visual-parity commit per the plan §1 row 17a/17b/17c.

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
