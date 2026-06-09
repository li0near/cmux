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
| 2026-06-07 | 19o (audit-fix) | `041853d02` | Independent code-audit pass (cross-checked by Plan agent + verifier) on phases A–E. Two HI-severity fixes landed inline: (a) **logger plumb** — `buildAbandonedBranchEntries` (line 131) and `BuildContext.buildSidechainEntries` (line 695) constructed fresh `ClaudeTranscriptBuilder()` without forwarding the parent's logger, so spec-only-not-corpus warnings were silently dropped on every nested transcript; fix threads `logger: self.logger` through. (b) **`.compact` accent divergence** — pre-existing pre-Phase-A inconsistency where live row dispatched `.dim` and detail-mode dispatched `.cyan`; detail mode now matches live row at `.dim`. Plus consistency lift: `HudPalette.color(for: TextStyle)` becomes single source of truth (collapses two parallel `EntryBodyView.textColor`/`AgentEntryView+CappedBody.color` switches that disagreed on `.thinking`). HI #2 (sync `String(contentsOf:)` in `resolveOffloadedOutput`) documented as known limitation in `MIGRATION_PLAN.md` §16.O for a future async-resolver pass. |
| 2026-06-07 | 19p (folder cleanup) | `d54f006ee`, `446046c16`, `090f91741`, `baa735f90` (4 commits) | Structural folder cleanup post-phases. **`d54f006ee`**: rename `Adapters/Claude/Parsers/` → `Dispatchers/`; `*LineParser` → `*LineDispatcher` (the per-type files are routing classifiers, not parsers — the line is already Codable-decoded by then). **`446046c16`**: move top-level `ClaudeLineDispatcher.swift` into `Dispatchers/` so the orchestrator co-locates with the per-type workers it calls (mirrors `Resolvers/` pattern). **`090f91741`**: extract `OffloadedOutputParser` to a NEW `Adapters/Claude/Parsers/` folder (now correctly named for content extractors — text/JSON content → structured value, distinct from `Dispatchers/` and `Resolvers/`). **`baa735f90`**: split the 427-line `ClaudeJSONLLine.swift` into 8 wire-type files under new `Adapters/Claude/Wire/` folder (one major type per file per CLAUDE.md rule); `AgentXrayJSON` (shared decoder used by both Claude + Codex via `TranscriptStream`) lifts to `Adapters/Common/AgentXrayJSON.swift`. Final four-way taxonomy under `Adapters/Claude/`: `Wire/` (raw decoded types), `Dispatchers/` (line → routing), `Resolvers/` (full-transcript → cross-line state), `Parsers/` (text/JSON → structured value). |
| 2026-06-07 | 19q (extractor migration) | `776325c52` | Migrate remaining content extractors out of `ClaudeTranscriptBuilder.swift` into `Adapters/Claude/Parsers/`. Five new parser types (each as a clean enum with named methods): `MCPToolNameParser` (was `parseMcpToolName`), `ToolInputParser` (was `summarizeToolInput`/`formatToolInput`/`extract*`/`truncated`), `ImageBlockParser` (NEW — closes audit's W1 dedup, two overloads handle JSON-shape and typed-Source shape), `ToolResultParser` (was `buildToolResultSections`/`rawSections`/`sectionForBlock`/`imageSection`), `UserContentParser` (was `buildUserContentSections`/`userImageSection`). Test files renamed in lockstep + relocated to `Tests/.../Adapters/Claude/Parsers/`. Builder shrinks 1441 → 1148 lines (−293). |
| 2026-06-07 | 19r (audit convergence) | `d39e95e81` … `55bcc87bb` (6 commits) | Independent re-audit + verifier pass cross-checked findings; six high-confidence cleanup commits landed. **`d39e95e81`**: drop dead `isCompactSummary` / `isMeta` checks in `classify()` (UserLineDispatcher already routes those away from `.render(.user)`). **`b9cba5c28`**: carry parsed payload on 5 `ClaudeSpecialKind` cases (`slashCmdInput`, `slashCmdOutput`, `systemReminder`, `skill`, `contextUsage`) — eliminates the per-meta-line double-classify in `emitSpecial` arms; `ClaudeContentDetector.classify(...)` now runs once at the dispatcher boundary, payload flows through. **`3a485c055`**: lift `firstText()` + new `allText()` to Wire layer's `ClaudeMessageContent`; lift `metaBody` to `ClaudeJSONLLine`; retire builder's `joinText` + `extractMetaText` (single source of truth for text projections, on the wire type). **`5de4f62ae`**: single `makeBranchLinkEntry(branch:totalRewinds:branchEntries:timestamp:)` factory; both branch-link emit sites delegate (was 30 LOC duplicated with subtle drift between `Self.loc` and `ClaudeTranscriptBuilder.loc`). **`a9fb691d2`**: drop dead vestiges — builder's `truncated` (live copy is in `ToolInputParser`), `ClaudeJSONLLine.toolUseID` field (decoded but never read), `SystemLineDispatcher`'s named-subtype arm functionally identical to `default:`. **`55bcc87bb`**: drop `AgentEntry.body.subentries` mirror — `subEntryToTopLevel` was producing a body-mirror walked by `EntryComputedCache` for cache-signature byte counts, but AgentEntry never goes through the cache (renderer takes `AgentEntryView` path which bypasses `EntryView`/`EntryComputedCache` entirely); ~25 LOC dead computation removed. Builder shrinks 1148 → 1050 (−98). 110 / 17 tests green throughout. |
| 2026-06-08 | 19s (Phase D-rev) | `4006c9a1f` … `bb4a9c524` (5 commits) | T5.2 finished, but **inverted the implementation strategy** — instead of shipping four hand-rolled rich renderers (JSON / Diff / Markdown / Code) inside the package, AgentX-ray now delegates detail-tab rendering to cmux-native surfaces. The original Phase D plan would have duplicated work cmux already does (bundled `marked.js` + `highlight.js` covering markdown / code / diff / json) and would have either added an SPM dep (Splash / Highlightr / HighlighterSwift / JSONPreview) or grown ~1500 LOC of custom tokenizers. The hybrid host-rendered shape lands the user-facing feature with zero new dependencies. **Three host-protocol seams** added with default no-op extensions: `detailBodyView(content:)`, `detailImageView(source:sourceEntryID:sectionIndex:)`, `detailExternalOpenAccessory(for:)` (last is `nil` this phase; wired when the language-detection follow-up lands real on-disk file paths). **Image carrier on `DetailContent`** (`imageSource`, `imageSectionIndex`) plus resolver branches in `resolveTopLevel.user` (user-paste images) and `resolveSubEntry.tool` (tool-returned images, e.g. Playwright `browser_take_screenshot`). New 4-test suite `DetailContentResolverImageTests`. New localization key `agentXray.detail.title.userImage`. **`TranscriptView.detailView`** rewrites the dispatch from a 5-arm `ContentType` switch into a 3-way branch (entries / image / body) calling `panel.host.detailBodyView/detailImageView`. **Four section-view stubs deleted** (`MarkdownSectionView`, `CodeSectionView`, `JsonSectionView`, `DiffSectionView`) — replaced by host. Foundation kept intact (Section / ContentType / sniffer / parsers / HudPalette / ImageThumbnailView) for the future transcript renderer. **cmux-side conformance** (`Sources/Panels/AgentXray/AgentXrayDetailRenderers.swift`, new file): wraps `MarkdownWebRenderer` for text (markdown passes through; code/diff/json/plain coerced to fenced blocks driving highlight.js) and Apple's `QLPreviewView` (modern `QuickLookUI` framework, NOT cmux's panel-coupled private wrapper) for images. Base64 → temp-file bridge under `NSTemporaryDirectory()/cmux-agentxray-images/<workspaceID>/` with per-workspace cleanup on `AgentXrayWorkspaceHost.deinit` and one-shot launch purge in `AppDelegate.applicationDidFinishLaunching`. Tests: 110 → 114 / 17 → 18 suites green. |
| 2026-06-08 | 19t (Phase E) | `b2a14e895` … `87a5ac1d1` (7 commits) | Phase E **redesign** — Phase D-rev's embed approach (in-package MarkdownWebRenderer + QLPreviewView wrappers driven by `host.detailBodyView` / `detailImageView`) was the wrong shape. cmux already has a complete panel-open pipeline (`Workspace.openFileSurfaces`) that fires when users click inline file paths in the terminal, dispatching to `MarkdownPanel` or `FilePreviewPanel` with full chrome — font controls, copy as markdown / HTML, edit toggle, "Open in…", image zoom/pan/rotate, find-in-content, spacebar QuickLook. AgentX-ray now redirects detail-tab opens through that pipeline: package writes content to a temp file with the right extension, calls new host method `openFileInPanel(_:activate:reuseExisting:)`, cmux opens a real panel. Subsumes the original Phase E small-deferral scope: HI #2 (no longer reads bytes — just hands `OffloadedOutput.path` to the host), M2 (no resolver read to test), FU 1 (file extension does the language-detection work), FU 2 (cmux panel has its own Open menu in chrome). **Inline image thumbnails dropped** — replaced with a clickable `↗ Image` link (`ImageEntryLinkView`) that defers all bytes work to click time; click short-circuits via `host.openImageInPanel(...)` before the resolver runs, avoiding a `DetailContent` carrier entirely. **`DetailContent` reshape**: drops `imageSource` / `imageSectionIndex`; adds `existingFilePath` for offloaded outputs; resolver's offloaded sync `String(contentsOf:)` read deleted (HI #2 resolved by avoidance). **Phase D-rev embed code swept**: `detailBodyView` / `detailImageView` / `detailExternalOpenAccessory` protocol methods + default extensions deleted; `AgentXrayDetailBodyView` / `AgentXrayDetailImageView` / `QLPreviewViewRepresentable` deleted from cmux app target; `import QuickLookUI` dropped; `public import SwiftUI` dropped from `AgentXrayHost.swift` (no more SwiftUI cross-boundary types). Cache renamed `AgentXrayDetailImageCache` → `AgentXrayDetailFileCache` (broader scope; root dir `cmux-agentxray-images` → `cmux-agentxray-files`; legacy dir purged at app launch for upgrade cleanup). Sub-agent / abandoned-branch transcripts keep in-package rendering — they're structured Entry arrays, not file-shaped. `TranscriptView.detailView` collapses to transcript-only with a defensive "opened externally" fallback. Tests: 114 → 110 / 18 → 17 suites (deleted `DetailContentResolverImageTests` — assertions referenced removed carrier fields; image-click flow becomes host-integration territory, manual smoke is sufficient). Net code shrinks substantially in the cmux app target (~140 LOC of view code gone). |
| 2026-06-08 | 19u (Phase F) | `a73d3a84b` … `4458cd082` (8 commits, plan called for 9 with 4 bundled into 5 to keep the cmux app target compiling per-commit) | Phase F **content-type cleanup** — Phase E's plumbing layered onto Phase D-rev's wrong-shape carriers. Three structural fixes: (a) Edit / MultiEdit input becomes `Section.text(_, .diffAdded/.diffRemoved)` at parse time (`ToolInputParser.diffSections`) so both inline rendering AND the detail-tab unified-diff materialization read the same structurally-typed data — replaces the `editOldString` / `editNewString` carriers on `AgentToolCall` and `ToolEntry`, and the `synthesizeUnifiedDiff` resolver helper. **Correctness bonus**: the prior `editStrings` helper kept only `MultiEdit`'s first edit; the new `diffSections` flattens every edit in arrival order. (b) `DetailContent` collapses its `body` / `contentType` / `entries` / `existingFilePath` mix into one discriminated `source: DetailSource` enum (file / text / image / transcript). The host's `openDetailTab` switches on the source variant directly — file paths go straight to `openFileInPanel`, inline text/image content materializes to a temp file with the suggested basename (extension drives cmux's panel dispatch), transcripts keep in-package rendering. **`openImageInPanel` host method dropped** — image clicks now flow through the unified `.image(...)` source and the same materialize-then-open pipeline as text. **Image-section short-circuit + `imageSectionForRequest` helper dropped** from `AgentXrayPanel.openDetail`. Resolver fix uncovered by the new tests: sub-agent transcript routing was discriminated by hard-coded section indices (`sectionIndex == 2 || (sectionIndex == 1 && count >= 3)`), false-positive on MultiEdit bodies with N diff pairs; switched to discriminating by section shape (`case .subentries`). (c) `HudPalette.color(for: TextStyle) -> Color` becomes `colors(for:) -> (foreground, background)`, returning a tinted background for `.diffAdded` (light green) and `.diffRemoved` (light red); `EntryBodyView` and `AgentEntryView+CappedBody` paint diff sections with a flat `Rectangle` so adjacent removed/added pairs read as one contiguous hunk. The `PaletteRole` overload at `:76` is unrelated and untouched. **`DetailContentShapeSniffer.sniff(...)`** adds a `.diff` arm using a 2-of-3 conservatism (≥2 of: `^diff --git`, hunk header `^@@ -X,Y +X,Y @@`, file-header pair `^--- a/` + `^+++ b/`) — same threshold philosophy as the JSON validity-parse arm. **Two-level dedup on materialization**: existing on-disk file short-circuits cold re-clicks; an `[String: Task<URL?, Never>]` map on `AgentXrayWorkspaceHost` short-circuits warm re-clicks during the write window. **Drops**: `ToolInputParser.editStrings`, `ToolEntry.editOldString` / `.editNewString`, `AgentToolCall.editOldString` / `.editNewString`, `DetailContent.synthesizeUnifiedDiff`, `AgentXrayHost.openImageInPanel`, `DetailContentShapeSniffer.languageHint(forFilePath:)`. **Test additions**: `ToolInputParserDiffSectionsTests` (8), 6 sniffer diff cases, `DetailContentResolverTests` (19) — first resolver coverage on this path. Tests: 110 → 143 / 17 → 19 suites. Plan: `/Users/I505728/.claude/plans/warm-jingling-fern.md`. |
| 2026-06-08 | 19v (Phase G — partial: G0/G1/G2a/G2b) | `24a20bf94`, `c9e734eab`, `b36effc9c`, `4bec941d8` (4 commits) | Phase G architectural redesign — first half of an 8-commit plan; the remaining four (G3/G4/G5/G6) are deferred to a follow-up session. Plan: `/Users/I505728/.claude/plans/streamed-cuddling-stream.md`. **G0 — skill discriminator (single-line tag-order check)**: deleted `Resolvers/ClaudeSkillCommandResolver.swift` (next-line lookup that required an `isMeta:true` `"Base directory for this skill:"` follow-up). Replaced by `UserLineDispatcher.isSkillShaped(_:)` — a user line is a skill iff its trimmed content starts with `<command-message>` (built-ins emit `<command-name>` first). Strictly more correct: corpus survey across 709 sessions (360 candidate slash-command lines) → TP=123, TN=199, FN=0, FP=38. The 38 FPs are all genuine plugin-skills the old rule missed (`/simplify`, `/claude-hud:configure`, `/claude-hud:setup`, `/engineering-defaults`, `/install-mcps`, `/swift-concurrency-pro`, `/swift-testing-pro`, `/swiftdata-pro`, `/swiftui-pro`). Drops `skillCommandUuids: Set<String>` from `ClaudeLineDispatcher.route(...)`, `UserLineDispatcher.parse(...)`, and `BuildContext`. **G1 — `TranscriptRoot` infrastructure**: new `Models/TranscriptRoot.swift` + `Models/TranscriptRoot+BranchOff.swift`. Synthetic root container indexed by `EntryID` with single uniform API: `append(_:)`, `mutate(id:_:)`, `remove(id:)`, `branchOff(at:link:)` plus sub-entry variants `appendSubEntry(parentAgentId:_:)` / `mutateSubEntry(id:_:)` / `subEntry(id:)`. The two-tier API preserves the existing type asymmetry between `Entry` (top-level, 5 cases) and `AgentEntry.SubEntry` (nested in agent turns, 2 cases). Private `EntrySlot` enum discriminates `topLevel(Int)` vs `agentSub(parentAgentId:, subIndex:)`; private `virtualRoot` sentinel never leaks onto `EntryID`'s public surface. `branchOff` caller contract: link id derived from `abandoned.first.id` (NOT divergence point) so multi-rewind to the same parent yields distinct ids. Index slots for entries that move into a branchLink's body are dropped in G1 — G4 will extend the index if it needs index-driven mutation through archived branches. New `Tests/CmuxAgentXrayTests/Models/TranscriptRootTests.swift` (Swift Testing, 12 cases). **G2a — dual-write**: `BuildContext` gains stored `var root = TranscriptRoot()`; new `mutating func appendEntry(_ entry: Entry)` helper writes to both legacy `entries` and `root`. Every existing `ctx.entries.append(...)` site routes through the helper (~20 call sites in `transcript()`, `dispatch(_:ctx:)`, `emitSpecial`, `flushPendingTurn`, `maybeEmitBranchLinks`). Debug-only assert at end of `transcript()` checks `ctx.entries == ctx.root.subEntries` for every fixture in `ClaudeTranscriptBuilderTests` — the safety net for G2b. **G2b — source-of-truth flip**: `transcript()` returns `ctx.root.subEntries`; `BuildContext.entries: [Entry]` deleted; assert removed. `appendEntry(_:)` becomes a thin wrapper over `TranscriptRoot.append(_:)`. **G3 attempt reverted**: collapsing `PendingTurn` (`subEntries: [PendingSubEntry]` accumulator + `toolIndexByID`) requires rewriting `mergeIntoPendingTurn` / `appendTextEvent` / `appendToolUse` / `attachToolResult` / `flushPendingTurn` together — without dual-write infrastructure for sub-entries (TranscriptRoot's index doesn't track sub-entries until parent AgentEntry is appended at flush time), the change can't land safely in one commit. Deferred. **Sidechain corpus survey** (run during 19v): 710 sessions, 36,113 sidechain lines. **0 uuid collisions** between sidechain and parent-session lines (Assumption 1: PASS). 204 orphan `parentToolUseID` references in 16 sessions, all in subagent files where the parent `messages.jsonl` is missing — not data corruption, just incomplete corpus when parent transcripts are archived/deleted while subagent files remain. Future G3 implementation must handle the orphan case gracefully (skip-or-warn fallthrough to the existing synthetic-tool path). Tests: 143/19 → 155/20 (+12 new TranscriptRootTests, +1 new suite). All green throughout the four landed commits. **Carry-forward to next session**: G3 (collapse PendingTurn + drop recursive sidechain), G4 (inline branch detection, delete `ClaudeBranchResolver` multi-pass + fixpoint, no LCA walk needed since rewind's new prompt's `parentUuid` IS the divergence point), G5 (queued-prompt §C inline FIFO replacing `ClaudeQueuedPromptResolver`), G6 (cleanup + docs). |
| 2026-06-08 | 19w (Phase G — G1.5 + G1.5-fix + G1.6) | `91d9b6da8`, `e7d23f387`, `486681b5e` (3 commits) | Two structural model refactors before G3a opens. **G1.5 — lift `SubEntry` into `Entry`** (`91d9b6da8`): drops `AgentEntry.SubEntry` (the two-case `.text(TextSubEntry) / .tool(ToolEntry)` variant pre-G1.5) and adds `.text(TextSubEntry)` and `.tool(ToolEntry)` directly to `Entry`. The "sub-entries can't appear at top level" invariant is enforced by the builder + a runtime assert in `TranscriptRoot.append(parent:entry:)` rather than the type system, in exchange for one uniform mutating API on `TranscriptRoot` (`append(parent: EntryID?, entry: Entry)` / `mutate(id:_:)` / `remove(id:)`). Body's `Section.subentries(_:)` case removed; `SynthesizedEntry` and `AgentEntry` carry top-level `subEntries: [Entry]` instead of folding nested entries through body sections. **G1.5-fix** (`e7d23f387`): drops `ToolEntry.subEntries` (sub-agent / Task tool transcripts will surface as top-level `AgentEntry` rows in a future commit; folding them under the originating tool entry was the wrong shape). **G1.6 — `TranscriptRoot` → `Transcript`; collapse mutation API to `slice`** (`486681b5e`): rebuild around recursive descent + flat-map index post-pass. Renames `TranscriptRoot` → `Transcript` (drops the legacy `Transcript = [Entry]` typealias). `AgentEntry.subEntries` and `SynthesizedEntry.subEntries` become `internal(set) var`; `Entry.subEntries` gains a settable case-rebuild accessor so `&entries[head].subEntries` is a writeable lvalue and recursion threads through Swift's `_modify` accessor chain without copy-extract-repack. Public mutation API collapses to `append(parent:entry:)` / `mutate(id:_:)` / `slice(from:length:replacingWith:)`; the unified `slice` subsumes both the legacy `remove(id:)` and the abandoned-branch fold (`branchOff(at:link:)` is a thin wrapper). Helpers `doAppend` / `doMutate` / `doSlice` are three lines each. Slice index post-pass applies two rules over the flat `[EntryID: [Int]]` map (drop ids in `[startIdx, startIdx+length)`; shift ids past the slice by net delta) then walks the replacement subtree once via `registerSubtree` to re-path the abandoned-tail entries (which the caller folded into `link.subEntries`) under their new nested paths. **Drops** the pre-G1.6 mutation machinery: `withSubEntries`, `withAppendedSubEntry`, `withRemovedSubEntryAt`, `mutateInside`'s reconstruction body, `indexNestedChildren`'s overload pair, `replaceTopLevelRange`, `topLevelIndex`, `isSubEntryOnlyCase`, the unused `remove(id:)` (subsumed by `slice`). Inline doc commitments (in `Transcript.swift`): type-level "real-world simplification" note (verified empirically — top-level + tail-only is the only slice shape today; corpus 85/85 rewinds across 200 Claude sessions land on a contiguous tail past the divergence point + zero non-tail call sites in `Sources/`; mutate closures never replace `subEntries` and never change `entry.id`), per-method algorithm doc on `slice`, `_modify` chain rationale on `doMutate`. Tests: 154/20 → 155/20 (+2 slice-coverage tests, −1 typealias-shape test); legacy `removeTopLevel()` test ported to `slice(...length:1, replacingWith:nil)`. Plan: `/Users/I505728/.claude/plans/transient-meandering-russell.md`. |
| 2026-06-09 | 19x (Phase G — G3 / G5 / G4 / G6 — Phase G complete) | `8faf28a6e`, `8f43cfac6`, `6df78b702`, `b53b3e776` (4 commits) | Phase G's second half: streaming-dispatcher cleanup. **G3** (skeleton-AgentEntry-in-Transcript, drop `PendingTurn`): the in-flight turn now lives directly in `Transcript.entries` from the first content-bearing assistant line; sub-entries flow into the skeleton via `Transcript.append(parent: skeletonId, ...)`. **G5** (inline FIFO queued-prompt, drop `ClaudeQueuedPromptResolver`). **G4** (per-line rewind detection + parallel-tool-call out-of-order pool, drop `ClaudeBranchResolver`). **G6 — streaming-dispatcher cleanup** (`b53b3e776`): replaces skeleton-tracking + `closePendingTurn` + multiple uuid maps with a per-line dispatch model where every JSONL line stands on its own. **Universal alias rule**: `Transcript.index` carries every JSONL line uuid — either as a real entry id (when the line's own append registers it) or as an **alias** mapping to its parent's resolved path (chained assistant lines, `tool_result` mutators, `turn_duration` mutators, skipped decorators). Children resolve in O(1) without re-walking the JSONL chain. **`BuildContext` shrinks from 18 fields to 4**: `logger`, `root`, `pendingPromptQueue: [(id: EntryID, text: String)]`, `awaitingParent: [String: ClaudeJSONLLine]`. **Dropped** (any of these reappearing in a future commit is a regression): `pendingAgentSkeletonId`, `pendingTurnLastTimestamp/LastMessageUuid/UsageMessageIds`, `turnThinkingCounter`/`turnAssistantTextCounter`, `closePendingTurn`, `recordUserPromptChild`+`userPromptChildrenByParent`, `dispatchedUuids`, `observeRawLine`, "skeleton" vocabulary, `agentEntryByAssistantLineUuid`, `pendingPromptMirrors`+tail-emit loop, `consumedSlashCmdUuids`, `toolCallById`+`toolStartedAtById`, `ClaudeTurnDurationResolver` pre-pass, synthetic-fallback `ToolEntry`+cross-turn id-reuse safeguard, `AgentToolCall.sidechainTranscript`+`withSidechain`, `ClaudeLineRouting.sidechainMain`, `ensureSkeleton`, `recordUserPromptChild`, `firstAbandonedPromptPreview`. **New abstractions**: `Transcript.registerAlias(lineUuid:path:)`, `ClaudeLineRouting.queueOperation(text:)`, `Adapters/Claude/Updates/ToolResultUpdate.swift`+`TurnDurationUpdate.swift` (`apply(_ entry: inout)` mutation closures invoked via `Transcript.mutate`). **`Transcript.swift` improvements**: `doSlice` returns the actual sliced length so `slice`'s post-pass shift uses the clamped value (latent-bug fix; no caller passes `length > available` today, but the landmine is gone). Per-key prefix comparison switched from `Array(P.prefix(depth)) == prefix` to elementwise loop (avoids per-key Array allocation; top-level slices automatically take the fast path). **`.branchLink` SynthesizedEntry kind trimmed**: `rewindIndex` / `totalRewinds` / `entryCount` / `firstPromptPreview` all dropped — only `branchRootUuid` remains. Display becomes a flat "Rewind" label. The pre-existing "Rewind X of Y" was always a "Rewind N of N" bug since both indices were equal at construction time. **`ToolEntry`** `body` / `status` / `durationMs` / `header` switch from `let` to `internal(set) var` so `ToolResultUpdate.apply` can mutate them. **Tests**: 158/20 → 161/20 green. Dropped two tests pinning behaviors the new design intentionally removes (within-turn duplicate `tool_use` overwrite, cross-turn `tool_use_id` reuse — both rely on `tool_use_id` non-uniqueness, but the API spec guarantees uniqueness). Added five new tests: out-of-order `tool_result` via `awaitingParent` pool drain; rewind detection folding abandoned tail into branchLink; queued slash-cmd FIFO pop via slash-cmd input arm (verified empirically in this very session); unconsumed enqueue stays as `.pending` UserEntry; `turn_duration` line stamping AgentEntry scalars. **Empirical premises** (verified 2026-06-09 against 200 sampled JSONL files / 31,267 lines): every assistant line has its own uuid (100%); `parentUuid` always resolves locally (100%, 0 dangling); single block per assistant line (99.97%, 4 outliers handled by block-index suffix); out-of-order lines (12 / 31,267 ≈ 0.04%, all resolved by pool+drain); pool single-child invariant (0/731 with 2+); top-level + tail-only slice (G1.6: 85/85 rewinds); ~3.21% of assistant lines parent at a skipped decorator line (`attachment/task_reminder`, `progress`, etc. — universal alias rule covers this with O(1) lookup); slash-cmd-only consumption is real and live in modern Claude Code. Plan: `/Users/I505728/.claude/plans/lexical-forging-ripple.md`. Phase G is now **fully landed**. |

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
P. **Sub-entry id format walks back the G6 brief's "no derived ids"
   directive.** The G6 brief said "NO `EntryID.derived(parent:kind:)`
   for thinking/text. The line's stableId IS the entry id." Shipped
   uses `EntryID.derived(parent: line.stableId, kind: "thinking-N" /
   "text-N")` instead. Reasoning: the bare-stableId form only works
   for single-block-per-line (the corpus norm at 99.97%), but the
   derived form handles the 0.027% multi-block-outlier case
   uniformly without conditional logic. The brief's "if a single line
   ever carries multiple blocks of the same kind, address with a
   block-index suffix" carve-out effectively required a derivation
   anyway; the shipped code makes that derivation unconditional.
   *(Stays — uniform handling preferred over conditional. Recorded so
   future readers don't try to "restore" the bare-stableId form.)*
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
