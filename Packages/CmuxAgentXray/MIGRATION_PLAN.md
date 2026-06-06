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
2. **Read [`docs/next-session-handover.md`](docs/next-session-handover.md)** — pending tasks
   from the 2026-06-05/06 refactor session, with cross-verification reminders for items
   that depend on JSONL corpus shapes.
3. Verify branch tip matches §14's latest row (`git log -1 --oneline`).
4. `swift build` + `swift test` from `Packages/CmuxAgentXray` should be green.
5. For UI-touching changes, `./scripts/reload.sh --tag agentxray --launch`.
6. Anything ambiguous → trust the code over the doc. If a doc claim is wrong,
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
| 2026-06-04 | 17a | (17a commit) | Visual-parity pass: new `Theme.swift`, `HoverBars.swift`, `StatusBarView.swift`, `AgentEntryView` extension files; `EntryIcon.swift` rewrite; per-row hairline divider removed. Tests 21 → 20. |
| 2026-06-04 | 17b | (17b commit) | `AttachStage` feature: 6-case enum + 3-color glyph precedence in `StatusBarView`. |
| 2026-06-04 | 17c | (17c commit) | Group 1 behavioural correctness: `EntryAnchorsKey`, `currentTopVisibleID`, `ScrollViewReader`, scroll-routing `.onChange` arms, boundary-id markers, detail-mode rendering, `triggerFlash` flash gate. |
| 2026-06-04 | 17d | (17d commit) | Forward-looking deferrals + parity audit: Group 3 / 4 / 5 swept ✅; F + H closed; A / B / C / G stay deferred. |
| 2026-06-05 | 18 | `1c49bdf29` … `b0624eab8` (9 commits) | Dogfood pass: session-attach + host-adapter overhaul. Host folded 6 files → 3 (PanelHost → PanelAdapter rename; FocusObserver + ScrollbarBridge + DebugMenu placeholder removed); `AgentXrayLogger` seam (os.Logger / cmuxDebugLog routing); resolver rewritten with two paths (restored-snapshot synthesis + scanner-based PID + hook-record-by-PID join); SSH transport infrastructure (`RemoteJSONLStream`, `JSONLLineFramer` with UTF-8 byte-carry); README documentation with flow + timeline diagrams. Tests 20 → 46. Five new §16 deferrals (J–N). |
| 2026-06-05 | 19a | `b6ce2bbe9` … `1662ceb0e` (4 commits) | Test-layout refactor (mirrored source tree under `Tests/CmuxAgentXrayTests/`); regression test for `attachment.queued_command` with `commandMode: "task-notification"` skip; `commandMode` field added to `ClaudeAttachment`; parser reference doc at `docs/claude-jsonl-mapping.md`. Tests 67 → 70. |
| 2026-06-05 | 19b | `d23b49954` | Sub-row icon column alignment: `.frame(width: Theme.Metric.subRowIconWidth)` pin on Tool / Thinking / AssistantText sub-rows so glyph + name columns align across kinds. |
| 2026-06-05 | 19c | `75c9951cd` | Interleaved thinking + assistantText sub-entries with tools — preserves JSONL arrival order ("narrate → tool → narrate → tool"). `subEntryEvents` log on `PendingTurn`; per-block stable ids; 3 new builder tests. Tests 70 → 73. |
| 2026-06-06 | 19d | `a68e60021` | TimeMarker + TextSubEntry + body unification: `TimeMarker.{clock, duration}` collapses `Header.timestamp` + `TrailingItem.duration`; entry-level `timestamp` becomes a computed projection of `header.timeMarker.clockDate`; `ThinkingEntry` + `AssistantTextEntry` merged into `TextSubEntry { kind: .thinking | .assistant }` with `AgentEntry.SubEntry` collapsed from 3 cases to 2 (`.text`, `.tool`); `AgentSubEntry` protocol dropped; `ToolEntry.toolName` now computed from `header.name`; body rendering unified through `cappedBody(_:onOpenDetail:)` walking `body.sections` and applying per-section `TextStyle` automatically. |
| 2026-06-06 | 19e | `eabac5f5e` | DetailRequest collapse: 12 case-shapes → single `.bodySection(targetID: String, sectionIndex: Int)`. Resolver becomes one arm with `resolveTopLevel` + `resolveSubEntry` helpers; `AgentXrayPanel.openDetail` walks both top-level entries and agent sub-entries to find a `targetID` match. `DetailContent.Kind` retained for now (used by `TranscriptView` icon/accent dispatchers). |
| 2026-06-06 | 19f | `3fc2108d2` … `7ad2c1527` (3 commits) | Builder cleanup: `ClaudeTranscriptBuilder` 1294 → 1192 lines via factored helpers (`loc(_:_:)` localization, `makeSystemEntry`, `makeTextSubEntry`, `planModeMetadata`, `AgentToolCall.withResult`/`withSidechain`); `appendAssistantText` + `appendThinkingText` collapsed to one `appendTextEvent(kind:_:)`; `PendingTurn`'s parallel `subEntryEvents`/`toolCalls`/`toolCallOrder`/`toolStartedAt` collapsed into one `subEntries: [PendingSubEntry]` + `toolIndexByID: [String: Int]` lookup. |
| 2026-06-06 | 19g | `572f65513` | Tier 1 of next-session-handover (T1.1): Grep tool icon swapped to `questionmark.text.page` / `.fill`. |
| 2026-06-06 | 19h | `175cd6a80`, `476db75da`, `63a787196` (3 commits) | Tier 2 of next-session-handover (T2.1–T2.7) in three bundles. **Bundle A** — MCP polish: `EntryIcon.tool(named:)` falls back to externaldrive icon for `mcp__`-prefixed names; `parseMcpToolName` strips `mcp__<server>__` so `Header.name` shows the bare tool name; `ToolEntry.mcpServer: String?` carries the server name and renders as a cyan chip in the sub-row header `extras` slot; `summarizeToolInput`'s default arm now tries a priority list of meaningful keys before falling back. **Bundle B** — `UserEntry.queuedState: QueuedState { .none, .consumed, .pending }` replaces the `wasQueued: Bool` + `isQueuedPending: Bool` pair, killing the impossible 4th state at the type level; `EntriesFilter` and `EntryView.shouldPulseIcon` updated. **Bundle C** — `joinText(from:filterTextBlocksOnly:)` collapses 5 near-duplicate `ClaudeMessageContent` extractors; `buildPendingUserEntry` becomes a 7-line wrapper of `makeUserEntry`; `buildSystemEntry`'s two arms converge through a shared `stripCommandOutputTags` tail. Tests stayed at 73 / 13 suites. |
| 2026-06-06 | 19i | `403711d98`, `26fc2e72c`, `56ad077ba` (3 commits) | Visual-polish pass on top of Tier 2. **403711d98** — `Theme.{Row,SubRow}.summary` renamed to `.title` (font slot styles `Header.title`); MCP server-as-name flip with new `label` slot in `subEntryHeader` (server takes the primary name slot, bare tool name moves to label); sub-row title font regression fix (was bigger than its name). **26fc2e72c** — `Theme.SubRow.name` and `.title` bumped 11pt → 12pt to match predecessor's tool-row HStack-level cascade. **56ad077ba** — fine-grained polish: SubRow.name + .title settle at 11.5pt, SubRow.meta bumped 10 → 10.5pt, sub-row title color drops the 0.78 opacity (now full primary), and a series of tool-icon picks (Edit/Grep/Bash/WebSearch/Todo*/Task*/plan-mode glyphs). |
| 2026-06-07 | 19j (Phase A) | _(this commit)_ | T3.1 landed. `DetailContent.Kind` (11 cases) dropped; direct fields `icon: EntryIcon` + `accent: PaletteRole` + `contentType: ContentType` populated by each resolver arm. New types: `Models/PaletteRole.swift`, `Panel/ContentType.swift` (foundation, with `.plainText` + `.transcript` cases — Phase D extends with `.markdown / .code / .json / .diff`). `HudPalette.color(for:)` extension resolves `PaletteRole` → SwiftUI `Color` at the view boundary so `DetailContent` stays SwiftUI-free. `TranscriptView.detailKindIcon(for:)` and `detailKindAccent(for:palette:)` deleted; `detailView` reads `content.icon.collapsed` + `palette.color(for: content.accent)` directly. |
| 2026-06-07 | 19j (fix) | `b3456f9cb` | Phase A fix: `PaletteRole` relocated `Models/` → `Views/` (color resolution is a view-layer concern; matches `HudPalette`'s existing pattern). `EntryView.kindAccentColor` collapsed to one-liner reading `PaletteRole.forEntry(entry).map { palette.color(for: $0) }` — single source of truth for live-row + detail-mode accent dispatch. |
| 2026-06-07 | 19k (Phase B) | `628b9fe4b` … (4 commits) | T4.1 landed. **B.0**: inline `buildPendingUserEntry` at its single call site + delete (vestigial 7-line wrapper to `makeUserEntry` with naming-clash to genuine `PendingTurn` accumulator). **B.1**: `Section` extended to 4 cases (`.text`, `.image(ImageSource)`, `.toolReference(toolName:)`, `.subentries`); new `Models/ImageSource.swift`, `Views/Sections/ImageThumbnailView.swift` (lazy base64 decode off-main via `Task.detached`), `Views/Sections/ToolReferenceChipView.swift` (inline pill with cyan MCP-server chip). `EntryComputedCache` updated for new variants + cap accounting. Inline rendering walkers (`cappedBody`, `EntryBodyView`) updated. Localization keys added under `agentXray.section.image.*`. **B.2**: rewrite `flattenToolResult` → `buildToolResultSections(_:isError:logger:)`. One Section per `tool_result.content[]` block in JSONL arrival order. `AgentToolCall.result` flips from `String?` to `[Section]?`. Spec-only-not-corpus block types (`redacted_thinking` / `search_result` / `document`) stubbed as `[type]` placeholders + `AgentXrayLogger.warning` emission with VERIFY-CORPUS-2026-06-07 inline comments. Assistant-emitted `image` block (also spec-only-not-corpus) drops with warning. **B.3**: user-paste image emission via `buildUserContentSections(from:)`; `ClaudeContentBlock.source` field added. `makeUserEntry` flips to sections-bearing primary signature with text-shorthand convenience for the four call sites that only carry strings. URL-mode images dropped silently per Phase B scope (corpus-empty). Tests: 73 → 90 (17 new across `ToolResultSections` + `UserContent` test files). |
| 2026-06-07 | 19l (Phase C) | `5fd81d2b3`, `20066fd21` (2 commits) | T3.2 landed via two-commit regression pattern. **C.1 (RED)**: new `Section.offloadedOutput(OffloadedOutput)` case (5th variant) + `Models/OffloadedOutput.swift` (path / sizeLabel / preview) + `Views/Sections/OffloadedOutputLinkView.swift` + walker arms + 7 tests (5 RED). **C.2 (GREEN)**: `buildToolResultSections` post-pass `promotePersistedOutput(_:)` walks every `.text` section and replaces matches with `.offloadedOutput`. Compiled-once `NSRegularExpression` matches the canonical `Output too large (<size>). Full output saved to: <path>` line — validated against 252 corpus occurrences. Robust to truncated tails (close tag optional). Detail-tab `resolveOffloadedOutput(_:tool:timestamp:)` arm reads the offloaded file at click time via `String(contentsOf:encoding:)`; fallback to localized error + inline preview when unreachable. New keys: `agentXray.section.offloadedOutput.link`, `agentXray.detail.subtitle.offloadedOutput`, `agentXray.detail.offloadedOutput.readError`. Tests: 90 → 97 (7 new). |
| 2026-06-07 | 19m (Phase D) | `843384994` | T5.2 foundation. `ContentType` extended from `.plainText / .transcript` to also cover `.markdown`, `.code(language:)`, `.json`, `.diff`. `TextStyle` extended with `.diffAdded`, `.diffRemoved`, `.codeMonospace` (§16.A pulls in). Four stub renderer views land in `Views/Sections/`: `MarkdownSectionView`, `CodeSectionView` (with optional language label), `JsonSectionView` (pretty-prints via `JSONSerialization`), `DiffSectionView` (per-line `+`/`-` coloring). Inline-rendering color dispatchers (`cappedBody`, `EntryBodyView`) extended for the three new TextStyle cases. Design choice: contentType is **not** stored on `Section.text` — it's derived at detail-tab resolve time by Phase E's sniffer. Avoids cascading a third axis through 12+ constructor + pattern-match sites. |
| 2026-06-07 | 19n (Phase E) | `81971aa5a` | T5.1 generalized. New `Panel/DetailContentShapeSniffer` with detection ladder: (1) leading-`{`/`[` + `JSONSerialization` validity → `.json` (Bash-output false-positive guarded by validity parse); (2) two-or-more `^### ` headings → `.markdown` (single-heading stays plain to avoid overfitting); (3) else `.plainText`. `mcpServer: String?` parameter reserved for future per-server hints; no Playwright allow-list (Playwright's `### Result/Ran` matches via the generic markdown rule). `splitMarkdownSections(text:)` extracts heading-bounded segments for the future rich markdown renderer. `DetailContent.resolveSubEntry` invokes the sniffer on tool-result text; `TranscriptView.detailBodyText` dispatches on `content.contentType` to the Phase D stub views. Tests: 97 → 110 / 16 → 17 suites green (13 new). |

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
A. ~~TextStyle expansion — diffAdded/diffRemoved/codeMonospace cases when diff rendering lands.~~ **✅ DONE in Phase D (2026-06-07)** — landed alongside `ContentType.diff` foundation; the diff renderer's full implementation ships as a follow-up PR.
B. Sub-agent transcript inline rendering — currently link-only; future: inline expand inside ToolEntry's body.subentries. *(Stays deferred — future UX evolution.)*
C. ToolEntry shape — likely to evolve as tool-call UX changes (user noted "I think it will change in the future"). *(Stays deferred — speculative.)*
D. ~~Notification name `cmuxClaudePromptSubmitted` — currently defined in cmux app; explore moving definition into package to remove one upstream touch.~~ **✅ DONE in Phase 2** — moved to `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/ClaudeAnchorPayload.swift`; see §15 entry from Phase 2 commit `18ff88fa5`.
E. cmux-app-side `Sources/Panels/AgentXray/` retains three
   `ObservableObject` / Combine surfaces (verified post-Phase-18 via
   `grep -rE 'import Combine|ObservableObject|@Published|AnyCancellable'`):
     - `AgentXrayPanelAdapter` conforms `Panel, ObservableObject` with
       `@Published titleTick: Int` (lines 25 / 49). Gated on cmux's
       `Panel` protocol convention — every cmux panel matches.
     - `AgentXrayWorkspaceHost` exposes `@Published currentFocus:
       ResolvedAgentSession?` (line 74) + `workspaceBridge:
       AnyCancellable?` (line 76) sinking `Workspace.objectWillChange`
       via Combine. Gated on `Workspace` itself being an
       `ObservableObject`.
     - `HostCancellable` (lines 505+) wraps `AnyCancellable` for the
       host protocol's observation tokens. Same gate as above.
   Migrate to `@Observable` + `AsyncStream` once (a) cmux's `Panel`
   protocol drops the `ObservableObject` requirement AND (b)
   `Workspace` becomes `@Observable`. Both are cmux-wide architectural
   changes, not AgentX-ray-scoped. The package itself
   (`Packages/CmuxAgentXray/Sources/`) is already `@Observable`-only —
   the only remaining `ObservableObject` / Combine references in the
   package are doc-comment text in `Behavior/Anchors/TurnAnchorStore`
   and `Host/Cancellable.swift`. *(Stays deferred — gated on upstream
   cmux modernization, not on macOS-floor or user-base ubiquity. The
   original entry's "macOS 15 ubiquitous in user base" framing was
   loose; Observation framework is macOS 14+ which we already target.)*
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
I. ~~Top-level `CmuxAgentXrayPanelView` is currently a minimal port of the
   spike's `AgentInspectorPanelView`.~~ **✅ Done** (2026-06-05) — audit
   confirmed all six spike features already ported during Phases 7 / 17a / 17c
   with renames: `InspectorRowAnchorsKey → EntryAnchorsKey`
   (`Views/TranscriptView.swift:550-558`), `currentTopVisibleId →
   currentTopVisibleID` (lines 28, 352-368), bulk-collapse scroll-clamp
   + bulk-expand materialize-kick (lines 138-155), `visibleTurnFilter →
   entriesFilter` (lines 129-132), status-bar pills (`StatusBarView.swift`).
   No code change needed.
J. ~~SSH "Set session id" UI affordance — Phase 18 shipped the SSH
   transport infrastructure but the UI is missing.~~ **✅ Done**
   (2026-06-05). Adds resolver path 3 (remote session id from
   `UserDefaults`), inline `RemoteAttachPromptView` mounted from the
   empty-state branch, "Change" link in `StatusBarView`, ControlPath
   piggyback so AgentX-ray's `ssh exec` rides cmux's existing
   ControlMaster, per-tab SSH inference via `TerminalSSHSessionDetector
   .parseSSHCommandLine` so opening `ssh user@host` inside a local-
   workspace terminal also surfaces the prompt, and remote `$HOME`
   resolution+caching by `(destination, port, identityFile, controlPath)`.
   Persistence keyed by `(destination, cwd, agentKind=.claude)`.
   Codex remote attach folded into §16.L. v1 limitations: stale id on
   remote `/new` (Change link is the user-controlled escape hatch);
   per-tab inferred ssh has `controlPath: nil` so each subprocess
   opens a fresh ssh connection (workspace-level remote rides
   ControlMaster correctly). Full flow diagrams (resolver decision
   tree + path 1/2/3 timelines + per-tab SSH inference + ControlPath
   piggyback wiring) live in `docs/session-attach.md`.
K. Daemon-side process enumeration over RPC for remote workspaces —
   would let remote panels auto-resolve (no manual sessionId entry)
   like local ones. Requires modifying `cmuxd-remote`
   (`daemon/remote/cmd/cmuxd-remote/main.go`) to add an `agent.list`
   or equivalent RPC method that returns `(panelID → claude/codex PIDs
   + cwd + transcriptPath)`, plus a manifest bump for baked cloud-VM
   images. Out of scope for the AgentX-ray fork-side work; needs
   coordination with the cmux daemon team. *(Stays deferred — depends
   on upstream daemon work.)*
L. **Deferred codex work (consolidated).** Folded together as the
   canonical "deferred codex" entry so a future codex pass picks up
   everything in one go. Three known gaps:
   1. **Restored-snapshot transcriptPath resolution.** Phase 18 path 1
      returns nil for codex because codex sessions live in date-
      bucketed `~/.codex/sessions/<y>/<m>/<d>/<sid>.jsonl` directories
      the snapshot doesn't carry. Codex via path 2 (live PID + hook
      record) still works — the hook record carries the explicit
      transcriptPath. So this is only a path-1 latency gap (slower
      attach for restored codex; resolves once the agent spawns and
      fires its SessionStart hook). Fix: either embed the transcriptPath
      in the snapshot (cmux-side change in `RestorableAgentSession`) or
      walk the date directories at resolve time.
   2. **SSH attach via session id (path 3).** Same date-bucket problem
      on the remote host — given a codex sessionId, we can't deterministically
      build the on-disk transcript path without walking
      `~/.codex/sessions/<y>/<m>/<d>/`. AgentX-ray currently gates the
      §16.J prompt to claude only (`ctx.agentKind == .claude` in path 3
      + `RemoteAttachPromptView` strings). Fix: extend `remoteTranscriptPath
      (forKind:sessionID:cwd:remoteHome:)` in `AgentSessionResolver` to
      also accept codex by walking remote `~/.codex/sessions/*/*/*/<sid>.jsonl`
      via one extra `ssh exec ls`-style probe, cache the result alongside
      `RemoteHomeResolver`'s home cache.
   3. **`codex resume` argv shape.** Codex CLI uses positional `codex
      resume <id>` (not `codex --resume <id>`). The §16.J prompt's
      detail string mentions `claude --resume <id>` only; when codex
      lands the kind-specific copy needs a parallel `agentXray.remote
      .prompt.detail.codex` entry that says `codex resume <id>`.
   *(Stays deferred — no current consumer asks for codex remote attach;
   the §16.J infrastructure is forward-compatible.)*
M. ~~Upstream cmux change `#4777` ("Launch restored agent sessions via
   startup commands", commit 17f529f63) replaced the pre-existing "type
   `claude --resume <id>` into the panel's PTY" restore mechanism with
   a script-based shell-argv mechanism. The user-visible behaviour
   change: the resume command no longer appears in the panel's
   scrollback. Worth confirming with the cmux team whether the scrollback-
   disappearance was deliberate before filing anything.~~ **✅ Resolved**
   — research subagent (2026-06-05) reviewed the PR description, commit
   message, three reviewer summaries (cubic, CodeRabbit, Greptile), and
   the test additions. Verdict: scrollback disappearance is a deliberate
   refactor side-effect (resume runs as Ghostty's `initialCommand` in a
   proper login shell instead of `initialInput` PTY echo, so cmux zsh
   integration re-enters), not a UX assertion. Don't file. AgentX-ray
   no longer depends on the prior behaviour either way.
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
O. **Async resolver for `DetailContent.resolveOffloadedOutput`.** The
   Phase C file-read currently uses synchronous `String(contentsOf:
   encoding:)` on the `@MainActor`. Corpus has files up to ~1.2MB —
   bounded but perceptibly janky on slow disks / very large outputs.
   Migrating requires making `DetailContent.resolve(...)` async and
   cascading through every caller (`AgentXrayPanel.openDetail`,
   `TranscriptView.detailView`). *(Stays deferred — needs a wider
   resolver-pipeline async refactor; tracked here so future drift is
   visible.)*
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
