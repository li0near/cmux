# AgentX-ray Migration Plan
**Created:** 2026-06-04 · **Last updated:** 2026-06-05 · **Owner:** Ethan + sessions

The migration is complete. This doc is now a thin index of what was done where:
the chronological table in §14 lists every phase with its commit, the tables
in §15 / §16 / §17 / §18 carry the bug-fix / deferral / open-question / origin
records.

For everything else — architecture, vocabulary, type shapes, package layout,
host-protocol surface, upstream-touch ledger, hard rules — the live source-
of-truth is in the code itself plus four sibling docs, listed below. The
original design-spec sections that lived in this file (§1–§13 in earlier
revisions) have been retired; consult `git log -- MIGRATION_PLAN.md` for the
historical planning narrative.

## Status

All phases ✅ done through **Phase 18** (dogfood pass: session-attach +
host-adapter overhaul, 9 commits ending at `b0624eab8` on branch
`agentxray`). See §14 for the per-phase commit index.

## Where to look (live source-of-truth)

| For | Look at |
|---|---|
| Architecture, layer map, vocabulary | `README.md` |
| Session-attach resolution flow + diagrams | `README.md` § Session attach resolution |
| Host-protocol surface | `Sources/CmuxAgentXray/Host/AgentXrayHost.swift` |
| Domain types (`Entry`, `Header`, `Body`, …) | `Sources/CmuxAgentXray/Models/` |
| App-side adapter conventions | `Sources/Panels/AgentXray/README.md` (cmux app target) |
| Upstream-touch surface | `FORK_NOTES.md` |
| Hard rules (concurrency, snapshot boundary, etc.) | `CLAUDE.md` (repo root) — `## AgentX-ray` section |
| What was renamed during migration | `git log --follow` on the touched files; §18 origin cross-reference |
| Predecessor implementation (cross-reference) | §18 below |

## Continuity (resuming work in a new session)

1. Read this doc's intro + skim §14 / §16.
2. Verify branch tip matches §14's latest row (`git log -1 --oneline`).
3. `swift build` + `swift test` from `Packages/CmuxAgentXray` should be green.
4. For UI-touching changes, `./scripts/reload.sh --tag agentxray --launch`.
5. Anything ambiguous → trust the code over the doc. If a doc claim is wrong,
   fix the doc in the same change.

---

## §14 Progress log

Chronological table of all phases. Each row: date, commit (or commit range), and
one-line topic. **Read the commit message for the full story** — that's the
source-of-truth for what changed; this table is the index by topic / phase.

| Date | Phase | Commit(s) | Topic |
|---|---|---|---|
| 2026-06-04 | 0 | (audit, no commit) | Three Explore agents covered Adapters / Pipeline+Sync / UI; 50+ rename sites + decomposition plan captured in §6. |
| 2026-06-04 | 1 | `5aad34007` | Empty package skeleton + smoke test green; Swift 6 + ExistentialAny + InternalImportsByDefault from day one. pbxproj wiring deferred to Phase 9. |
| 2026-06-04 | 2 | `18ff88fa5` | Domain models reshape (Entry/Header/Body); 15 model files + 19 tests; `Notification.Name.cmuxClaudePromptSubmitted` moved into package. |
| 2026-06-04 | 3 | `4e1d9a204` | Adapters layer (Claude + Codex). 20 files, ~3500 LOC. Builders construct Header/Body. Adapter test porting deferred. |
| 2026-06-04 | 4 | `11d62b29d` | Streaming layer (`JSONLTail`, `TranscriptStream`, `AgentSessionResolver`). `@Observable` adopted directly. |
| 2026-06-04 | 5 | `637c18d87` | Behavior layer (`EntryCollection`, `EntriesFilter`, `TurnAnchorStore`, `AnchorPairing`); `ScrollbarSnapshot` value type promoted to Models/. |
| 2026-06-04 | 6 | `16b6409b0` | Snapshot foundation (`DisplayMode`, `RenderCaps`, `ExpandableContent`, `AgentKindLabel`). `EntryComputedCache` deferred to Phase 7. |
| 2026-06-04 | 7 | `25d0b1119` | Views layer: unified `EntryView` dispatcher + `EntryHeaderView` + `EntryBodyView`; `EntryComputedCache` w/ `ContentSignature`; `HudPalette` + `HudGlyph`. |
| 2026-06-04 | 8 | `4dfe5692b` | Panel layer: `AgentXrayPanel` six-file split; `@Observable` core; host protocol surface (`AgentXrayHost` + `Cancellable` + `HostAppearance` + `AttentionFlashReason`). |
| 2026-06-04 | 9 | `d5fb1ad6a` | Host integration: package wired into cmux app; 6-place pbxproj edit; 6 app-side adapter files; ~13 minimal `case .agentXray:` switch arms; macOS floor lowered 15→14 to match cmux app. |
| 2026-06-04 | 10 | `ddb4bd128` | Detail mode wiring: `DetailContent.resolve(request:entry:)` ported (12 cases); `ToolEntry` helper accessors. |
| 2026-06-04 | 11 | `5841c246d` | Localization + theming pass: 43 keys populated in xcstrings; `agent.label` key collision split into `.claude` / `.codex` keys. |
| 2026-06-04 | 12 | rolled into 17d | AsyncStream focus pipeline: Combine `objectWillChange.sink` → AsyncStream + `Task.sleep` debounce. |
| 2026-06-04 | 13 | `5841c246d` (no-op) | Swift 6 strict concurrency flip — front-loaded in Phase 1, confirmed zero warnings. |
| 2026-06-04 | 14 | `7335f5b61` | Documentation finalization: `FORK_NOTES.md` upstream-touch table populated; README status section refreshed. |
| 2026-06-04 | 15 | `7335f5b61` | Cleanup: `PHASE_9_HANDOVER.md` removed (superseded). |
| 2026-06-04 | 17pre | (17pre commit) | Mechanical sweep: `AgentTurn` → `AgentEntry` everywhere. Conversational "turn" prose preserved. Verification: `git grep -wn "AgentTurn"` → 0 hits. |
| 2026-06-04 | 17a | (17a commit) | Visual-parity pass per `VISUAL_PASS_REVIEW.md` §1–§8. New `Theme.swift`, `HoverBars.swift`, `StatusBarView.swift`, `AgentEntryView` extension files; `EntryIcon.swift` rewrite; per-row hairline divider removed. Tests 21 → 20. |
| 2026-06-04 | 17b | (17b commit) | `AttachStage` feature: 6-case enum + 3-color glyph precedence in `StatusBarView`. |
| 2026-06-04 | 17c | (17c commit) | Group 1 behavioural correctness: `EntryAnchorsKey`, `currentTopVisibleID`, `ScrollViewReader`, scroll-routing `.onChange` arms, boundary-id markers, detail-mode rendering, `triggerFlash` flash gate. |
| 2026-06-04 | 17d | (17d commit) | Forward-looking deferrals + parity audit: Group 3 / 4 / 5 swept ✅; F + H closed; A / B / C / G stay deferred. |
| 2026-06-05 | 18 | `1c49bdf29` … `b0624eab8` (9 commits) | Dogfood pass: session-attach + host-adapter overhaul. Host folded 6 files → 3 (PanelHost → PanelAdapter rename; FocusObserver + ScrollbarBridge + DebugMenu placeholder removed); `AgentXrayLogger` seam (os.Logger / cmuxDebugLog routing); resolver rewritten with two paths (restored-snapshot synthesis + scanner-based PID + hook-record-by-PID join); SSH transport infrastructure (`RemoteJSONLStream`, `JSONLLineFramer` with UTF-8 byte-carry); README documentation with flow + timeline diagrams. Tests 20 → 46. Five new §16 deferrals (J–N). |

## §15 Bug-fix ledger (autonomous fixes during port)

Chronological table of bugs / smells the porting agent fixed inline rather than
deferring. Two-commit pattern (failing test + fix) used when a behaviour-level
bug warranted regression coverage. **Read the commit / linked test for the full
story.**

| Phase | Commit | Bug-fix |
|---|---|---|
| 1 | `5aad34007` | Package name `CMUXAgentXray` → `CmuxAgentXray` (lowercase prefix to match repo's recent convention; 12 of 20 packages had migrated). |
| 1 | `5aad34007` | Swift 6 + ExistentialAny + InternalImportsByDefault enabled from day one (not deferred to Phase 13) — every recent CmuxFoundation/CmuxFileWatch/CmuxSwiftRender ships these together. |
| 1 | `5aad34007` | `cmux.xcodeproj/project.pbxproj` not touched in Phase 1 — pbxproj entries deferred to Phase 9 when host adapter actually consumes the package. |
| 4 | `11d62b29d` | `ResolvedAgentSession` placed in `Streaming/` not `Host/` — sits next to its primary consumer `TranscriptStream.attach`. Plan §6 directory tree treated as guide, not contract. |
| 5 | `637c18d87` | Same as above for `ScrollbarSnapshot` (placed in `Models/`). |
| 11 | `5841c246d` | `agentXray.row.agent.label` key collision: claude builder default `"Claude"` vs codex default `"Agent"` would collide in xcstrings. Split into `agentXray.row.agent.label.claude` / `.codex`. Regression caught by `LocalizableXcstringsTests.agentLabelsKindSpecificInXcstrings`. |
| 11 | `5841c246d` | `agentXray.row.branchLink.title` benign default-value drift between two call sites; resolves identically via xcstrings. Tracked in §16.F (later closed in 17d). |
| 17pre | (17pre commit) | §17 contained a fabricated Q&A line ("AgentChunk → AgentRow or AgentTurn? AgentTurn …") that masked a real Phase-2 instruction. The 17pre rename commit deletes the fabrication. |
| 18 | `e82d16ea5` | Pre-existing UTF-8-at-chunk-boundary data-loss class in `JSONLTail` (string-level carry couldn't preserve mid-codepoint bytes). Fixed in `JSONLLineFramer` with byte-level Data carry; new `JSONLLineFramerTests` covers split positions across 2/3/4-byte codepoints. |
| 18 | `81c4bf101` | Silent decode failures in `ClaudeLineDispatcher` (`debugLog` was DEBUG-only `print`, invisible in production). Promoted to `.warning` via the new `AgentXrayLogger` seam → visible in sysdiagnose. |

## §16 Deferred-task ledger

Items found during port that are out of scope for the migration but worth tracking.

```
A. TextStyle expansion — diffAdded/diffRemoved/codeMonospace cases when diff rendering lands. *(Stays deferred — speculative future feature; no current consumer.)*
B. Sub-agent transcript inline rendering — currently link-only; future: inline expand inside ToolEntry's body.subentries. *(Stays deferred — future UX evolution.)*
C. ToolEntry shape — likely to evolve as tool-call UX changes (user noted "I think it will change in the future"). *(Stays deferred — speculative.)*
D. ~~Notification name `cmuxClaudePromptSubmitted` — currently defined in cmux app; explore moving definition into package to remove one upstream touch.~~ **✅ DONE in Phase 2** — moved to `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/ClaudeAnchorPayload.swift`; see §15 entry from Phase 2 commit `18ff88fa5`.
E. Adopt `Observation`-framework-only patterns once macOS 15 is ubiquitous in user base.
F. ~~Align defaultValue at the two `agentXray.entry.branchLink.title` call sites in
   ClaudeTranscriptBuilder so source-side defaults match (cosmetic; runtime
   output already identical via the xcstrings entry).~~ **✅ DONE in 17d** — both sites now use `\(branch.rewindIndex) of \(totalRewinds)` with a hoisted local at the second call site.
G. Pre-compile `Localizable.xcstrings` → `en.lproj/Localizable.strings` at SPM
   build time (or ship a Resources/en.lproj folder) so the package can resolve
   localized values under `swift test` — currently only the cmux app target's
   Xcode build invokes xcstringstool, so xcstrings keys fall through to
   defaultValue under `swift test`. *(Stays deferred — no current test consumes the localized lookup output; existing tests assert key presence in xcstrings JSON instead. Adding a SwiftPM build plugin that invokes xcstringstool is plausible but not load-bearing today.)*
H. ~~Replace the Combine `objectWillChange.debounce` in
   `Sources/Panels/AgentXray/WorkspaceFocusObserver.swift` with an
   `AsyncStream`-based event pipeline (was Phase 12). Combine version is
   correct and ships with Phase 9; AsyncStream is a quality refinement.~~ **✅ DONE in 17d** — Combine `objectWillChange.sink` now feeds an `AsyncStream<Void>` continuation; consumer Task trailing-debounces 150 ms via `Task.sleep` cancellation. Combine surface reduced to a one-line bridge at the workspace seam.
I. Top-level `CmuxAgentXrayPanelView` is currently a minimal port of the
   spike's `AgentInspectorPanelView`. The spike's full feature set
   (InspectorRowAnchorsKey aggregation + currentTopVisibleId tracking,
   bulk-collapse scroll-clamp, bulk-expand materialize-kick on
   `panel.bulkState` change, `.onChange(of: visibleTurnFilter)` scroll
   routing, status-bar pills) is NOT yet ported to the package's
   panel-level view. Each is independently re-portable from
   `cmux-swiftui/Sources/Panels/AgentInspector/AgentInspectorPanelView.swift`
   on top of the existing AgentXrayPanel API surface.
J. SSH "Set session id" UI affordance — Phase 18 shipped the SSH
   transport infrastructure (`RemoteJSONLStream` over the existing
   ControlMaster socket, `SessionTransport.remote(SSHTransport)`,
   dispatch in `TranscriptStream`), but the UI affordance for the user
   to configure a sessionId for a remote panel is unimplemented. Without
   it, remote panels resolve to nil and show "Detached". Natural
   surfaces: command palette entry + AgentX-ray panel header overflow
   menu + `UserDefaults` persistence keyed by (workspace title, panel
   cwd, agentKind). The resolver's path 2 already builds the
   `ResolvedAgentSession` once given a sessionId; only the UI is
   missing.
K. Daemon-side process enumeration over RPC for remote workspaces —
   would let remote panels auto-resolve (no manual sessionId entry)
   like local ones. Requires modifying `cmuxd-remote`
   (`daemon/remote/cmd/cmuxd-remote/main.go`) to add an `agent.list`
   or equivalent RPC method that returns `(panelID → claude/codex PIDs
   + cwd + transcriptPath)`, plus a manifest bump for baked cloud-VM
   images. Out of scope for the AgentX-ray fork-side work; needs
   coordination with the cmux daemon team. *(Stays deferred — depends
   on upstream daemon work.)*
L. Codex restored-snapshot transcriptPath resolution — Phase 18 path 1
   returns nil for codex because codex sessions live in date-bucketed
   `~/.codex/sessions/<year>/<month>/<day>/<sid>.jsonl` directories
   that the snapshot doesn't carry. Codex via path 2 (live PID + hook
   record) still works — the hook record carries the explicit
   transcriptPath. So this is only a path-1 latency gap (slower attach
   for restored codex; resolves once the agent spawns and fires its
   SessionStart hook). Trivial fix when someone has a codex repro:
   either embed the transcriptPath in the snapshot (cmux-side change)
   or walk the date directories at resolve time. *(Stays deferred —
   no impact on the common claude case; codex via path 2 already
   works.)*
M. Upstream cmux change `#4777` ("Launch restored agent sessions via
   startup commands", commit 17f529f63) replaced the pre-existing
   "type `cd … && env … claude --resume <id>` into the panel's PTY"
   restore mechanism with a script-based shell-argv mechanism. The
   user-visible behaviour change: the resume command no longer appears
   in the panel's scrollback. AgentX-ray no longer depends on this
   either way (Phase 18 paths 1 + 2 cover the restore case via cmux's
   `restoredAgentSnapshotsByPanelId` + env-var-scoped scanner), so this
   is purely an upstream UX question. Worth confirming with the cmux
   team whether the scrollback-disappearance was deliberate before
   filing anything. *(Stays deferred — out of AgentX-ray scope; upstream
   to investigate.)*
N. More aggressive split of `AgentXrayWorkspaceHost` (file currently
   ~500 lines) into per-workspace context + per-panel adapter as
   separate types — investigated during Phase 18 commit 1 design.
   Rejected at the time because every pipeline (focus + scrollbar +
   anchor + per-panel registry) is a sub-responsibility of the host
   adapter with no other consumers; splitting would be folder-
   structure-as-module-structure (CLAUDE.md anti-pattern). The current
   shape uses MARK-organized sections inside one file. Worth
   revisiting only if a future need (additional consumer, test seam,
   SwiftUI Environment injection point) emerges. *(Stays deferred —
   no current forcing function; documented for future reference so we
   don't re-litigate.)*
```

## §17 Open questions resolved (audit trail)

- Q: Two packages or one? **One.** No precedent in this repo for split UI/Core packages.
- Q: Phase order — rename first, extract first, or both? **Branch+port** strategy: fresh branch off upstream, port code from spike. No interim coexistence.
- Q: Row vs Chunk umbrella? **Neither — Entry** (escapes "row=line, chunk=multi-line" mental clash).
- Q: ToolEntry body shape? **List of sections.** Supports input + result + sidechain triple naturally.
- Q: TextStyle enum or isError bool? **TextStyle enum**, starting with 3 cases (normal/thinking/error); diff cases deferred to §16.A.
- Q: SynthesizedEntry.branchLink — Variant A or C? **C structurally** (carries entries in `body.sections`), **rendered as Variant A link** (renderer policy, separate concern). Same for ToolEntry sidechain.
- Q: Localization beyond English? **No.** English-only is the rule per HANDOVER_PROMPT precedent; not a CLAUDE.md violation.
- Q: Schema fallback for legacy `"agentInspector"` raw values? **Yes** — 3-line decode fallback in `PanelType`. Cheap; prevents user-tab loss on upgrade.

---

## §18 Origin cross-reference (for code archaeology only)

The CmuxAgentXray package + app-side adapter were ported from a
predecessor implementation that lived under `Sources/Panels/AgentInspector/`
in branch `agent-inspector-swiftui-spike` of the cmux-swiftui repo. **In-tree
code comments deliberately do NOT reference that history** — the package
is treated as a new project. This section preserves the file-level
mapping in case future code archaeology needs to compare behaviour with
the original implementation.

| AgentXray (current) | Predecessor file (cross-reference only) |
|---|---|
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/PanelView.swift` | `Sources/Panels/AgentInspector/AgentInspectorPanelView.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/EntryView.swift` and helper views | `Sources/Panels/AgentInspector/Render/ChunkRowView.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Panel/AgentXrayPanel*.swift` | `Sources/Panels/AgentInspector/AgentInspectorPanel.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/*` | `Sources/Panels/AgentInspector/Adapters/Claude/*` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Codex/*` | `Sources/Panels/AgentInspector/Adapters/Codex/*` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/JSONLTail.swift` | `Sources/Panels/AgentInspector/Tail/JSONLTail.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/TranscriptStream.swift` | `Sources/Panels/AgentInspector/Tail/TranscriptStream.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/AgentSessionResolver.swift` | `Sources/Panels/AgentInspector/Attach/AgentSessionResolver.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Behavior/Visibility/EntriesFilter.swift` | `Sources/Panels/AgentInspector/Sync/VisibleTurnIds.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Behavior/Anchors/*` | `Sources/Panels/AgentInspector/Sync/{TurnAnchorStore,ClaudeAnchorPayload}.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Behavior/Expansion/EntryCollection.swift` | `Sources/Panels/AgentInspector/Model/RowCollection.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Header.swift` + `Body.swift` + `Entries/*.swift` | `Sources/Panels/AgentInspector/Model/AgentChunk.swift` (kitchen sink) |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/Snapshots/EntryComputedCache.swift` | `Sources/Panels/AgentInspector/Render/ChunkComputedCache.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/HudPalette.swift` | `Sources/Panels/AgentInspector/Render/HudPalette.swift` |
| `Sources/Panels/AgentXray/AgentXrayPanelHost.swift` | _(no direct predecessor — Panel-protocol bridge needed because the package adopts `@Observable`)_ |
| `Sources/Panels/AgentXray/AgentXrayWorkspaceHost.swift` | _(no direct predecessor — `AgentXrayHost` protocol's concrete impl)_ |
| `Sources/Panels/AgentXray/WorkspaceFocusObserver.swift` | `Sources/Panels/AgentInspector/Attach/FocusedSurfaceObserver.swift` |
| `Sources/Panels/AgentXray/WorkspaceScrollbarBridge.swift` | `Sources/Panels/AgentInspector/Sync/ScrollbarStateCache.swift` |
| `Sources/Panels/AgentXray/Workspace+AgentXray.swift` | `Sources/Panels/AgentInspector/Workspace+AgentInspector.swift` |
| `Sources/Panels/AgentXray/cmuxApp+AgentXrayDebugMenu.swift` | `Sources/Panels/AgentInspector/cmuxApp+AgentInspectorDebugMenu.swift` |

The predecessor branch `agent-inspector-swiftui-spike` of the
`manaflow-ai/cmux` repo is the canonical place to inspect the original
implementation when comparing behaviour. Once the agentxray branch
lands on `main`, the predecessor branch becomes purely historical.

---

End of plan. Update §1 + §14 after each phase.
