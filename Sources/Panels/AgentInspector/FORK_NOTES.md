# Agent Inspector — Fork Notes

This is a **fork-side feature**. The cmux fork tracks upstream
`manaflow-ai/cmux`, and this directory (`Sources/Panels/AgentInspector/`)
is the home of all new code. Most of the implementation lives here and
will not conflict on upstream merges.

A small number of *upstream files* have surgical edits — listed below — to
register `PanelType.agentInspector` and route through cmux's exhaustive
switch sites. **On every upstream pull, re-verify each line in this table**
and re-apply if upstream replaced the surrounding code.

## Phase 0 upstream-touch surface

| File | What we added | Why |
|---|---|---|
| `Sources/Panels/Panel.swift` | `case agentInspector` to `PanelType` enum + `agentInspector` branch in `init(from:)` decoder. | Register the new panel kind. |
| `Sources/Panels/PanelContentView.swift` | `case .agentInspector:` arm in `renderedPanel` (instantiates `AgentInspectorPanelView`). Added `.agentInspector` to the `case .markdown, .filePreview, .rightSidebarTool:` list in `shouldInstallPaneDropTarget`. | Render the panel; behave like markdown for drop-target gating. |
| `Sources/Workspace.swift` | `case .agentInspector: return nil` in `sessionPanelSnapshot(...)` switch (~line 567); `case .agentInspector: return SurfaceKind.agentInspector` in `surfaceKind(for:)` switch (~line 8527). | Skip session persistence in Phase 0; map to a stable surface-kind tag. |
| `Sources/CmuxLifecycleEventPublishing.swift` | `case .agentInspector: return "agent_inspector"` in `cmuxEventSurfaceKind(_:)`. | cmux event-bus surface tag. |
| `Sources/TerminalPaneDropTargetView.swift` | `case .agentInspector: return nil` in the panelType-routing switch. | No editor/terminal drop semantics for the inspector. |
| `Sources/ContentView.swift` | `case .agentInspector:` arms in `commandPaletteSurfaceKindLabel(for:)` and `commandPaletteSurfaceKeywords(for:)`. | Make the inspector discoverable in the command palette. |
| `Sources/Search/GlobalSearchDocuments.swift` | Added `.agentInspector` to the existing `case .terminal, .filePreview, .rightSidebarTool:` group in the `kind` switch. | Title-only search index for the inspector (no body content yet). |
| `Sources/cmuxApp.swift` | One line inside `#if DEBUG CommandMenu("Debug")`: `AgentInspectorDebugMenu(appDelegate: appDelegate)`. | Open-from-debug-menu entry. The menu group itself lives in this directory's `cmuxApp+AgentInspectorDebugMenu.swift`. |
| `Sources/Workspace.swift` | Relax `private var isProgrammaticSplit = false` to module-internal so `Workspace+AgentInspector.swift` can wrap programmatic splits the same way `splitPaneWithMarkdown` does. Single-character change (drop `private`). | Required for the side-by-side pane UX (split the focused pane and drop the inspector in the new sibling). |
| `Resources/Localizable.xcstrings` | New keys: `agentInspector.title`, `agentInspector.placeholder.header`, `agentInspector.placeholder.noSession`, `agentInspector.debug.menu.openCurrent`, `commandPalette.kind.agentInspector`. | Localization. Additive only; never conflicts. |
| `cmux.xcodeproj/project.pbxproj` | New PBXFileReference, PBXBuildFile, PBXGroup, PBXSourcesBuildPhase entries for the files under `Sources/Panels/AgentInspector/`. Generated with the `xcodeproj` Ruby gem. | Register new compilation units in the cmux target. |

## Files owned by this fork (no upstream conflict expected)

```
Sources/Panels/AgentInspector/
  AgentInspectorPanel.swift
  AgentInspectorPanelView.swift
  Workspace+AgentInspector.swift
  cmuxApp+AgentInspectorDebugMenu.swift
  FORK_NOTES.md
  DECISIONS.md
  Adapters/
    Claude/
      ClaudeJSONLLine.swift
      ClaudeChunkBuilder.swift
      ClaudeHookSessionStore.swift
      ClaudeBuilderConsts.swift                  # Phase A (named numeric thresholds)
      ClaudeContentDetector.swift                # Phase A (isMeta content classifier)
      ClaudeBranchResolver.swift                 # Phase A (rewind-tree walker)
      ClaudeRenderPolicy.swift                   # Phase A (line-routing policy)
    Codex/
      CodexRolloutLine.swift
      CodexChunkBuilder.swift
      CodexHookSessionStore.swift
      CodexSyntheticTimestamps.swift
  Attach/
    AgentSessionResolver.swift
    FocusedSurfaceObserver.swift
  Detail/
    AgentInspectorDetailContent.swift            # Phase A++ → extended in Phase B
    AgentInspectorDetailView.swift               # Phase A++ → extended in Phase B
  Model/
    AgentChunk.swift                             # MetaChunk added in Phase A
    AgentToolCall.swift                          # sidechainTranscript added in Phase A
  Render/
    HudPalette.swift
    ChunkRowSnapshot.swift                       # MetaSnapshot added in Phase B; ExpansionResolver added in cascade refactor
    ChunkRowView.swift                           # MetaChunkRow added in Phase B; bulk-managed @State removed in cascade refactor
    InspectorIcon.swift                          # Phase A++ + Phase B icons
    ClaudeModelNameMap.swift                     # Phase A++
    InspectorCaps.swift                          # Phase B (per-section cap policy)
    InspectorStatusBar.swift                     # Phase C (icon-pill row)
  Sync/
    ScrollbarStateCache.swift                    # Phase B (terminal → inspector sync)
    TurnAnchorStore.swift                        # Phase B
    InspectorSyncMode.swift                      # Phase B
    VisibleTurnIds.swift                         # Phase B v2 (visible-turn filter algorithm)
    ClaudeAnchorPayload.swift                    # Phase C (live-anchor payload from claude_anchor socket)
    InspectorRewindVisibility.swift              # Phase C (rewind toggle)
    InspectorExpansionMode.swift                 # Phase C (auto-expand toggle)
  Tail/
    JSONLTail.swift
    TranscriptStream.swift

cmuxTests/AgentInspector/
  ClaudeChunkBuilderTests.swift                  # extended in Phase A with rewind/sidechain/recap/multi-PR/meta cases
  ClaudeHookSessionStoreTests.swift
  CodexChunkBuilderTests.swift
  JSONLTailTests.swift
  AgentSessionResolverTests.swift
  ClaudeModelNameMapTests.swift                  # Phase A++
  InspectorIconTests.swift                       # Phase A++
  AgentInspectorDetailContentTests.swift         # Phase A++
  TurnAnchorStoreTests.swift                     # Phase B
  VisibleTurnFilterTests.swift                   # Phase B v2 → renamed in Phase C
  LiveAnchorReceiverTests.swift                  # Phase C
  ClaudeBranchResolverTests.swift                # Phase A
  ClaudeContentDetectorTests.swift               # Phase A
  ClaudeRenderPolicyTests.swift                  # Phase A
  AgentInspectorBulkExpansionTests.swift         # cascade refactor (BulkOutcome + ExpansionOverrides + ExpansionResolver)
cmuxTests/Resources/AgentInspector/
  claude-sample.jsonl
  claude-hook-sessions.json
  codex-sample.jsonl
  claude-rewind-tree.jsonl                       # Phase A fixture
  claude-sidechain-task.jsonl                    # Phase A fixture
  claude-recap.jsonl                             # Phase A fixture
  claude-multi-pr.jsonl                          # Phase A fixture
  claude-meta-content.jsonl                      # Phase A fixture
```

## Reapplying after an upstream pull

1. `git pull upstream main`
2. Resolve any conflicts in the upstream-touch files above. Each conflict
   is a one-line addition; preserve our `case .agentInspector:` arms.
3. Re-run the pbxproj registration script if any upstream file was added or
   if the project structure changed materially.
4. `./scripts/reload.sh --tag agent-inspector` and run the Phase 0
   verification gate from the implementation plan.

## Local build environment notes (macOS 26 / Tahoe + Xcode 26.4+)

cmux pins Zig 0.15.2, but Apple unified TBD target strings in Xcode 26.4+
(`arm64-macos` → `arm64e-macos`). Stock Zig 0.15.2 can't read the new
libSystem.tbd and fails with `undefined symbol: _free, _getenv, _sigaction…`.
Refs: [ghostty-org/ghostty#11991](https://github.com/ghostty-org/ghostty/issues/11991),
[Homebrew zig 0.15.2_1 patch](https://github.com/Homebrew/homebrew-core/commit/65c0019eac45be44fbd5b81397399e731e060741).

**One-time setup:**

```bash
brew install zig@0.15                   # Homebrew's patched 0.15.2 (keg-only)
xcodebuild -downloadComponent MetalToolchain   # Required by Ghostty's Metal build
```

**Every reload:**

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agent-inspector
```

The patched zig must come first in PATH so `ensure-ghosttykit.sh`'s
`command -v zig` picks it up; `CMUX_ZIG` covers `build-ghostty-cli-helper.sh`'s
override env var. Stock homebrew `zig` 0.16.0 fails because Ghostty's
`build.zig` requires exactly 0.15.2 via `requireZig`.

## Upstream-touch additions for restored-session wrapper fix

| File | Purpose | Lines | Risk on upstream merge |
|---|---|---|---|
| `Sources/RestorableAgentSession.swift` | `case .claude:` in `resumeArguments` discards `launchCommand.executablePath` and rewrites `arguments[0]` to bare `"claude"` so the cmux wrapper resolves at exec time | ~25 lines added; no signatures changed | Low — additive within an existing switch case; conflicts only if upstream restructures `resumeArguments` |
| `docs/proposals/claude-wrapper-path-precedence.md` | Standalone PR-draft doc documenting the bug, the existing wrapper architecture, the fix, and a maintainer test plan | NEW (no merge risk) | None — new file in a new directory |

## Phase C upstream-touch additions for live-anchor wire

| File | Purpose | Lines | Risk on upstream merge |
|---|---|---|---|
| `CLI/cmux.swift` | After the existing `clear_notifications` socket call in the `prompt-submit` claude-hook handler (~line 17320), send a new v1-text `claude_anchor <surfaceUUID> <turnId> <sessionId> <transcriptBytes>` command via `sendV1Command`. Skipped silently if any required field is missing. | ~18 lines added; no signatures changed | Low — additive, isolated to the `prompt-submit` case body |
| `Sources/TerminalController.swift` | New v1 router branch `case "claude_anchor":` (~line 2504) plus a small `claudeAnchor(_ args:)` private handler near `notifyTargetQueued` (~line 15569) that parses tokens, reads `ScrollbarStateCache.shared.latest(for:)`, and posts `Notification.Name.cmuxClaudePromptSubmitted` with `ClaudeAnchorPayload`. | ~70 lines added; no signatures changed | Low — additive case + private handler |
| `Sources/GhosttyTerminalView.swift` | New entry in the `extension Notification.Name` block (~line 10344): `cmuxClaudePromptSubmitted`, with a comment naming the AgentInspector consumer. | 5 lines added | Low — additive at the bottom of an enumeration |

## Phase D upstream-touch addition for hookbin precedence fix

| File | Purpose | Lines | Risk on upstream merge |
|---|---|---|---|
| `Resources/bin/claude` | Inverted priority in `resolve_hook_cmux_bin()`: prefer `$self_dir/cmux` (the cmux that ships in the *same* bundle as the wrapper) over `$CMUX_BUNDLED_CLI_PATH`. Fixes a regression in the tagged debug build where stale `CMUX_BUNDLED_CLI_PATH` env from production cmux leaked into terminals and routed claude hooks to the wrong cmux app, breaking AgentInspector auto-attach. | ~15 lines added, ~5 lines reordered | Low — bash-only, internal to the wrapper. Conflicts only if upstream rewrites `resolve_hook_cmux_bin`. |

Pre-existing `Resources/shell-integration/cmux-zsh-integration.zsh` is untouched.

## Current state and known limitations

The full feature surface, architecture, tests, and tech-stack
notes live in
`~/.claude/plans/crystalline-seeking-firefly.md` §1–§4. This
file's job is the upstream-touch ledger (above) plus the deferred
known-issues catalog and design-invariant checklist below.

For agent workflow guidance — LSP vs grep, when to delegate to
`Explore`, Apple/Swift doc-source priority (Xcode DocC →
`developer.apple.com` via `/browse-url` skill → swift-evolution →
source), and the verify-before-trust checklist — see
`AGENT_WORKFLOW.md` in this directory. Read it before any
non-trivial inspector work.

Branch `agent-inspector` is synced with `upstream/main` (last
merge: 76 upstream commits; `vendor/bonsplit` pinned to `ddb21d5`).
**Tests:** 141 passing in the AgentInspector subset.

### Known issues deferred to follow-up

The cross-validated catalog with full root-cause + repro lives in
`~/.claude/plans/crystalline-seeking-firefly.md` §5. Headlines:

1. **Blank screens on bulk-collapse and on at-bottom-band crossing
   (PRIMARY OPEN BUG)** — `LazyVStack` reports `contentHeight`
   with estimated heights for off-screen rows, which lag reality
   after rows shrink. Every scroll-clamp primitive (`proxy.scrollTo`,
   `.scrollPosition(id:)`, `.defaultScrollAnchor(.bottom)`,
   `.onScrollGeometryChange`) reads the same stale total. Mitigation
   shipped: deferred-async `scrollToBottom` on
   `panel.bulkState` collapse-direction handler in
   `AgentInspectorPanelView.swift:179-184`. Reduces but does not
   eliminate the symptom. Proposed next step: `NSViewRepresentable`
   wrapping `NSScrollView`+`NSTableView`. See plan §5.A and
   `DECISIONS.md` "Don't-re-walk list" for the full attempted-and-
   reverted approaches.
2. **Filter ping-pong hysteresis** — `recomputeVisibleTurnFilter`
   can churn at the stay-band boundary on fast scrolls. Not
   user-reported; revisit if dogfood shows flicker.
3. **`makeExpandable` overflow flag false-positive** when truncation
   removed nothing meaningful — cosmetic.
4. **Terminal-stage button feedback** — `Collapse` / `Expand`
   buttons don't visually disable at terminal stages. Click is a
   no-op but UI gives no signal.
5. **Initial freeze on first at-bottom-band crossing** —
   `ChunkRowSnapshot.from(...)` cost (`makeExpandable` +
   word-count splits per visible chunk) for ~200 chunks of long
   content can pause the first transition. Plan §7.3 / §7.4 for
   memoization + word-count-on-chunk proposals.

### Design invariants enforced (not in README)

Cross-validated against the code; rationale and code refs in
`~/.claude/plans/crystalline-seeking-firefly.md` §6.

1. **Snapshot-boundary policy** — rows below the LazyVStack hold
   no observable references. Value types + stable closures only.
   Custom `Equatable` for SwiftUI diff skipping. See
   `Render/ChunkRowView.swift:28-32`.
2. **No state mutation in view-body computations** (CLAUDE.md).
3. **Snap-back-first bulk semantics** — first bulk click reverts
   user's manual fiddles in the OPPOSITE direction; subsequent
   clicks advance. Direction-aware and asymmetric.
4. **Stepped expand/collapse** — each click advances exactly one
   stage; terminal-stage clicks are true no-ops.
5. **Cascade-free row updates** — bulk action publishes ONCE; every
   row updates SYNCHRONOUSLY in the same body pass.
6. **Universal pixel-offset clamp model** (verbal spec, NOT
   shipped) — see plan §6.6.
7. **Tagged debug builds only** —
   `./scripts/reload.sh --tag agent-inspector`.
