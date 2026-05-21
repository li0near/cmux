# Agent Inspector — Decision Log

This log records non-trivial choices made during autonomous Phase 1-4
implementation while the user was AFK. Each entry: **what was decided,
alternatives considered, and rationale**. Read top-to-bottom for chronological
order.

---

## Phase 0 carry-overs

- **`Sources/Workspace.swift` `isProgrammaticSplit`: `private` → internal.**
  Required so `Workspace+AgentInspector.swift` can wrap programmatic splits
  the same way `splitPaneWithMarkdown` does. Considered: a small wrapper
  function in Workspace.swift, but adding more lines to upstream-touch
  ledger is worse than a single-character access-modifier reduction.
- **Drop-overlay enabled (`paneDropTargetOverlay = true`).** Verified
  empirically that this is NOT the cause of the divider drag-zone issue
  (test #12 showed disabling it didn't help). Keeping the inspector
  consistent with markdown/filePreview/rightSidebarTool semantics.
- **Divider drag issue parked as task #12.** Will revisit after the panel
  has real interactive content; the placeholder might just be too small a
  test surface for the issue.

---

## Phase 1: Auto-attach + Claude transcript render

### Decisions

- **Chunk model lives in `Model/AgentChunk.swift` as a sum type, not a class
  hierarchy.** Reason: keeps the renderer pure-value, satisfies the
  snapshot-boundary policy trivially, and lets us reuse the same shape for
  both Claude and Codex without inheritance.

- **`ClaudeJSONValue` (the loose JSON wrapper used to decode `tool_use.input`
  / `tool_result.content`) is named "Claude" but lives in
  `Adapters/Claude/`.** Codex re-uses it. If a third agent ever needs a
  different JSON shape we can move it up to `Model/`. Not worth the move
  yet.

- **`FocusedSurfaceObserver` subscribes to `Workspace.objectWillChange`
  with a 150ms debounce.** Workspace publishes for many reasons (tab
  selection, layout, color theme, etc.) so a coarse subscription + debounce
  is simpler than threading a fine-grained @Published focus signal through
  Workspace's already-large public API. The debounce keeps thrashing in
  check; the dedup on `lastEmittedKey` keeps subscribers seeing only real
  session changes.

- **`ClaudeHookSessionStore` and `CodexHookSessionStore` use `DispatchSource`
  vnode watches with 100ms debounce.** Identical to `MarkdownPanel`'s
  pattern. We do not poll. When the file doesn't exist yet (cmux launched
  but Claude hasn't been started), we fall back to a 1-second retry timer
  rather than installing a directory watch, which would require more
  bookkeeping for the inspector's still-rare "Claude not running" case.

- **`JSONLTail` reads in 64KB chunks and carries partial trailing lines
  across reads.** Necessary because Claude flushes JSONL writes lazily; a
  partial line written mid-flight can be completed many milliseconds later.
  We never emit a partial line; we wait for the newline.

- **All chunk decoding errors are silently ignored.** A single malformed
  line shouldn't stall the stream — we just skip it. Phase 4 adds a
  `decodingErrorCount` field surfaced in the status bar so users can see if
  the file is unhealthy.

- **The renderer follows the snapshot-boundary policy strictly.**
  `ChunkRowView` is `Equatable`, takes only an immutable
  `ChunkRowSnapshot` value and a `HudPaletteToken` (a value-typed mirror
  of `HudPalette`); it imports nothing from `AgentInspectorPanel` /
  `TranscriptStream` / `Workspace`. The chunk-list `LazyVStack` calls
  `.equatable()` on each row.

- **Empty AI chunks are not flushed.** When a Codex `<system-reminder>`
  user line arrives mid-response, we don't push the pending AI chunk
  prematurely — same pattern is in `ClaudeChunkBuilder`. Caught by
  `CodexChunkBuilderTests.testChunkBuilderProducesExpectedChunks()`.

### Test fixtures

- `cmuxTests/Resources/AgentInspector/claude-sample.jsonl` — 9-line
  recorded session with one user prompt, one assistant response (text +
  thinking + tool call + tool result), one system command output, one
  hard-noise system reminder, one structural system entry, and one compact
  summary. Verifies all five classification paths.

- `cmuxTests/Resources/AgentInspector/claude-hook-sessions.json` — 3
  records across two workspaces, two of which share the same
  `(workspaceId, surfaceId)` so we can verify `record(forWorkspaceId:,
  surfaceId:)` picks the most-recently-updated entry.

- `cmuxTests/Resources/AgentInspector/codex-sample.jsonl` — 9-line Codex
  rollout covering session_meta, turn_context, event_msg user_message,
  multiple consecutive assistant response_items (verifies AI-chunk
  folding), a noise-only user response_item (verifies it doesn't split
  the AI chunk), and a real follow-up user message.

### Test execution

Tests run via `xcodebuild -scheme cmux-unit -only-testing:...` filtered to
the AgentInspector test classes. The full `cmux-unit` run hangs in this
environment because the test bundle is hosted in the running `cmux DEV`
app and other unrelated tests block on UI startup. The targeted run
finishes in ~14 seconds and was used as the regression gate for Phases 1+2.

## Phase 2: Codex adapter

### Decisions

- **Codex synthesises monotonic timestamps.** Codex rollout JSONL has no
  per-line timestamps. `CodexSyntheticTimestamps` interpolates between
  `mtime - 1h` and `mtime` based on line index. Adequate for ordering
  and the "follow tail" scroll mode; Phase 3 sync will treat these
  anchors as approximate (real anchors come from prompt-submit hook
  events instead).

- **`AgentSessionResolver` picks the most-recently-updated record across
  Claude and Codex.** When both stores have a record for the same
  `(workspaceId, surfaceId)`, the resolver compares `updatedAt` and
  picks whichever is fresher. Claude wins ties.

- **`CodexHookSessionStore` reuses `ClaudeHookSessionRecord`.** The two
  stores share an identical schema — only the file basename differs. We
  also accept `rolloutPath` as an alternate field name on Codex records
  for forward compatibility.

## Phase 3: Scroll-sync — direction reset

### Decisions

- **Click-jump deleted as a fake requirement.** The previous scoped-down
  Phase 3 included a `jumpToPairedTerminal()` action wired to
  `onTapGesture(count: 2)` on each chunk row. Two problems made it
  effectively dead UX:
    1. SwiftUI's text-selection gesture (`.textSelection(.enabled)` on
       inner Text views) intercepts double-click for word selection at
       a higher priority than the row-level tap. Clicking a message
       body almost never triggered the jump.
    2. The jump target was always the currently-focused session — the
       inspector by design attaches only to the focused tab, so
       "jumping to the paired terminal" is a no-op for any user who
       isn't actively typing into the inspector pane to scroll. The
       only effect was shifting firstResponder back to the terminal,
       which a single click on the terminal area already does.

  More fundamentally, with proper bidirectional scroll-sync (the
  remaining Phase 3 work), the two views are co-aligned by definition —
  there's no destination to "jump" to. Click-jump is the wrong shape of
  feature for this surface.

  Removed: `Render/ChunkRowActions.swift`, `AgentInspectorPanel.jumpToPairedTerminal()`,
  the `actions: ChunkRowActions` field on `ChunkRowView`, the
  `onTapGesture(count: 2)` modifier, and the `actions` construction
  in `AgentInspectorPanelView.transcriptList`.

- **Phase 3 proper: full bidirectional scroll-sync is the next
  meaningful work.** Still requires:
    1. Extending `cmux claude-hook prompt-submit` / `stop` to emit
       anchor records with terminal row + JSONL byte offset.
    2. A Ghostty scroll observer hooked to `NSScrollView.boundsDidChange`
       on `GhosttySurfaceScrollView`'s contentView. Off-main, debounced.
    3. A `BidirectionalScrollBridge` with timestamp interpolation and a
       120 ms loop guard.
    4. Optional: a `SyncOverlayView` drawing connector lines between
       matching anchors. Lower priority than 1–3.

  Plan and design when bandwidth allows. Until then, the inspector and
  terminal scroll independently and `followTail` is the only
  alignment mechanism.

## Phase 4: Polish — light scope

### Decisions

- **Skipped: keyboard shortcut entry in `KeyboardShortcutSettings.Action`.**
  The Action enum is exhaustively switched in ~6 sites (label, defaults,
  category groups, etc.). Each switch site that I'd need to extend is in
  upstream Workspace.swift / KeyboardShortcutSettings.swift, increasing
  fork-merge surface. The Debug menu entry is sufficient for this AFK
  ship; shortcut can land in a follow-up session.

- **Skipped: command palette integration.** The palette pipeline
  (`CommandPaletteSearch`, orchestrators) has its own command registry
  that requires more cmux-internals familiarity than is wise to extend
  without the user available to verify. Debug menu entry remains the
  open path for now.

- **Skipped: per-turn context-attribution badge and team chips.** These
  rendering enhancements need real Claude session data to verify the
  output looks right; deferred to a future session.

- **Kept: terminal-styled rendering with the claude-hud palette,
  follow-tail mode, status-bar
  showing attached/detached state, agent kind, sessionId prefix and cwd.**
  This is the working surface that the user will see.

## Post-AFK fix: auto-attach didn't actually attach

The user came back and reported the inspector said "no agent attached" even
when a Claude session was running in the focused terminal. Root causes:

1. **Foreign hook shim.** The user's `~/.claude/settings.json` had every
   Claude hook (including `SessionStart`) routed through `caudex`'s
   `session-hook.sh`, not cmux's `claude-hook session-start`. As a result,
   `~/.cmuxterm/claude-hook-sessions.json` had only stale records from a
   previous setup; new sessions never registered.

2. **Inspector lost session on its own focus.** When the user clicked the
   inspector pane (e.g. to scroll), `FocusedSurfaceObserver` saw the
   non-terminal focus and emitted nil, detaching the panel.

3. **Stale Phase 0 placeholder copy** still claimed "Auto-attach lands in
   Phase 1."

### Fixes

- **`AgentSessionResolver` now falls back to disk** when both hook stores
  miss. It enumerates `~/.claude/projects/<encoded-cwd>/*.jsonl` for the
  focused terminal's working directory (encoding rule:
  `"/path"` → `"-path"`, mirrors `SessionIndexStore.encodeClaudeProjectDir`)
  and picks the freshest jsonl by mtime. This makes the inspector work
  regardless of which hook shim is installed — it follows the on-disk
  transcripts cmux can already see.

- **`FocusedSurfaceObserver` now remembers the last focused
  `TerminalPanel`.** When focus moves to a non-terminal panel (e.g. the
  inspector itself), the observer keeps the previous resolution so the
  inspector keeps streaming. It only re-resolves when focus moves to a
  *different* terminal, or when the underlying hook file changes.

- **Updated placeholder copy** to match Phase 4 reality: "No session yet.
  Focus a terminal running claude or codex — the inspector follows the
  focused terminal automatically."

- **Added `AgentSessionResolverTests.testDiskFallbackPicksFreshestJsonl`**
  — verifies disk fallback against an injectable `claudeProjectsRoot`.
  The resolver gained a `claudeProjectsRoot` init parameter for
  testability (default still resolves to `~/.claude/projects`).

### Limitation

- Disk fallback uses the terminal's `directory` (Ghostty's reported cwd
  via OSC). If the user's shell doesn't emit cwd, fallback can't kick in.
  In practice, Ghostty's shell-integration emits cwd reliably for cmux
  terminals, so this is rare. Documented for future hardening.

## Phase 4+ rich rendering

Originally Phase 4 was scoped to "light polish only." User feedback after
the first user-visible build: "the inspector isn't powerful enough.
The information shown currently is just conversation histories, not even
as detailed as claude code itself." So Phase 4 expanded to match
claude-devtools-level transcript detail.

### Decisions

- **Always render thinking text** when the AI chunk has it. A dim italic
  block above the assistant body, prefixed with `⊡ thinking`. Was being
  parsed but never shown.
- **Token usage on AI chunk header**. Aggregates `input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`
  across all assistant messages folded into the chunk. Format: `in 12.3k ·
  out 1.4k · cache 5.6k · write 200`.
- **Full tool input as `key: value` lines**. Not just the one-line summary.
  Each top-level field on its own line, long values truncated per-field.
  Lives in `AgentToolCall.inputDetail`; rendered between the tool name
  and its result.
- **Full tool result body** (truncated to 24 lines). Was previously a
  240-char preview. Stored in `AgentToolCall.result`.
- **Subagent indicator on Task tools**. When `Task` is invoked,
  `subagent_type` is extracted (e.g. `general-purpose`) and rendered as a
  magenta `[general-purpose]` chip next to the tool name. Inner subagent
  chunks (`{sessionId}/agent_{agentId}.jsonl`) are NOT yet folded — that
  needs a separate SubagentLinker, deferred.
- **`ClaudeUsage` decoder gained an explicit memberwise + Decodable init**
  so test fixtures can construct `ClaudeMessage(role:, model:, content:,
  stopReason:)` without supplying `usage:`. Tests would otherwise fail
  with "missing argument for parameter 'usage'".

## Tab-switch follow — five iterations

User's setup: inspector pane on the right, two/three terminal tabs on the
left, each running its own claude session in the same working directory.
Tab switches in the left pane should make the inspector follow.

### Decision history

1. **Initial 250ms polling timer** (Combine `Timer.publish(every: 0.25)`).
   Worked at the observer level — `terminalId` log changed across
   switches. User pushed back: "the polling observer isn't particularly
   optimal. Investigate whether cmux has certain hooks or events that can
   let the inspector know terminal/tab/surface/claude session switches
   natively."

2. **Replaced polling with native `Notification.Name.ghosttyDidFocusSurface`**.
   cmux already posts this on every focus / tab / surface change at
   `Sources/Workspace.swift:14087`. Subscribing via
   `NotificationCenter.default.addObserver` recomputes synchronously on
   the actual event with zero polling. Kept a slow 2s fallback timer
   (`Timer.publish(every: 2.0, on: .main, in: .common)`) for late
   `TerminalPanel.directory` updates that don't fire the notification.

3. **Disk fallback collapsed three terminals to one session.** When
   multiple claude sessions share a cwd, "freshest jsonl in the project
   directory" is the same file regardless of which terminal you're on.
   Need a per-terminal disambiguation.

4. **Tried cmux's `RestorableAgentSessionIndex.processDetectedSnapshots`**
   (the vault-registered scanner). Dead end: cmux's vault registry only
   has `Pi`, `Antigravity`, `Grok` built-ins. Claude is handled only via
   the hook-store path, which is broken in the user's caudex setup.
   Wrapped the scanner in `AgentProcessSnapshotCache` (1.5s TTL) so the
   full system process scan doesn't run per tick. Kept as resolver layer
   2 — harmless no-op for Claude, useful for future-registered agents.

5. **Built a Claude-specific scanner: `ClaudeProcessSessionScanner`**.
   Three sub-iterations:
   - **5a. Per-PID lsof with `proc.name.hasPrefix("claude")` filter.**
     Failed: claude on macOS is a Node binary; proc name is `node`, not
     `claude`. Filter rejected everything.
   - **5b. Dropped name filter, ran lsof on every cmux-scoped PID for
     the surface.** Found a UUID-namespace bug: observer was passing the
     bonsplit `TabID` (returned by `surfaceIdFromPanelId`) as the
     surface ID, but `CMUX_SURFACE_ID` is the panel UUID
     (= `TerminalSurface.id` = `TerminalPanel.id`). They're different
     UUIDs. Fixed by passing `terminal.id.uuidString` directly. See
     `Sources/RestorableAgentSession.swift:1012-1013` for the upstream
     reference pattern.
   - **5c (current). Async + batched.** Single `lsof -F pn` for the
     whole system, filtered to `~/.claude/projects/.../*.jsonl`. For
     each cmux-scoped shell PID, walks the `processesByPID` parent →
     children tree and looks up descendant PIDs in the lsof map. Cached
     for 1.5s; runs on a `qos: .utility` background queue; resolver
     returns nil while cache is warming and the next focus event picks
     up the result. Reasoning: cmux only attributes the *shell* PID to a
     surface; the actual `claude` process is a descendant 1-2 hops
     deeper and doesn't carry `CMUX_SURFACE_ID` in its env. The tree
     walk catches those descendants without making the user's shell
     re-export env vars.

### Resolver layer order (4 layers)

In `AgentSessionResolver.resolve(workspaceId:surfaceId:cwdHint:)`:

1. `ClaudeProcessSessionScanner.shared.resolve(workspaceUUID:, surfaceUUID:)`
   — newest. Per-(workspace, surface) Claude session via tree-walk + batched
   lsof. Returns nil while cache is warming.
2. `resolveFromProcessSnapshot` via `AgentProcessSnapshotCache` —
   vault-registered scanner. No-op for Claude.
3. Hook stores (Claude + Codex). Empty in caudex-shimmed setups.
4. `resolveFromDisk` — most-recent jsonl by mtime in cwd. Cannot
   distinguish terminals sharing a cwd.

### Open questions (handed off)

- Whether the latest layer-1 scanner actually resolves distinct sessions
  per tab in the user's environment is **unverified at the time of this
  log**. Captured in `~/temp/github/agent-inspector-resume-handover.md`
  as the first task on resume.
- If lsof returns no jsonls, candidate native fallbacks are
  `proc_pidfdinfo()` (faster, no subprocess) or kqueue-based correlation.
  Notes in the resume handover doc.

### Logging gotcha

cmux's `cmuxDebugLog` redaction parser eats the trailing portion of a
log message after a recognized "redactable key" (`cwd=...`). `resolved=`
must come BEFORE `cwd=` in the format string or it gets consumed as part
of the redacted cwd value. Format used:

```
agentInspector.recompute resolved=… panelId=… cwd=…
agentInspector.scanner workspace=… surface=… candidates=…
agentInspector.scanner refreshed entries=…
```

## Phase A++ rendering revamp + detail panel

User feedback after the first user-visible build: the inspector duplicated
content already visible in claude's TUI (assistant body text, full user
prompts) and the metadata layout was cramped. This phase rebuilds the row
renderer around *hidden* information, drops the duplicated content, adds
expand/collapse controls, and introduces a sibling detail tab for content
that exceeds an inline cap.

### Decisions

- **AI assistant body dropped from rendering.** The terminal already shows
  it. The inspector instead surfaces what's hidden: thinking, tool inputs,
  tool results, cache token deltas, per-turn duration, per-tool duration,
  team-member chips on Task tools.

- **User prompts kept as compact one-line markers** (truncated to 80 chars)
  with an inline expand revealing the full text. They're useful as
  turn-boundary anchors and are short enough not to compete with the
  primary surface.

- **Inline expansion cap at 200 lines / 8 KB** (`ChunkRowSnapshot.Caps`).
  Above the cap, the row truncates inline AND surfaces an `↗ Open detail`
  link that opens a sibling tab in the same pane via the new detail-mode
  factory (`Workspace.openAgentInspectorDetail`). Cap rationale documented
  on the type.

- **Detail panel reuses the existing `agentInspector` panel kind in
  `.detail(content:)` mode** rather than introducing a new `PanelType`
  case. Keeps the fork-touch surface unchanged. Detail tabs hold a frozen
  `AgentInspectorDetailContent` snapshot, don't auto-attach to a session,
  and don't stream — they're pure read-only views.

- **Per-action SF Symbol vocabulary** in `InspectorIcon.swift`. Lifted
  semantically from claude-devtools' Lucide vocabulary (Brain → `brain`,
  Wrench → `wrench.adjustable`, User → `person`, Terminal → `terminal`,
  Layers → `square.3.stack.3d`) but adds finer-grained per-tool icons
  available in the SF Symbols catalog (`doc.text` for Read,
  `pencil.tip.crop.circle` for Edit/Write/MultiEdit, `apple.terminal` for
  Bash, `magnifyingglass.circle` for Grep, `person.2` for Task,
  `globe.americas` for WebSearch, `arrow.down.doc` for WebFetch,
  `list.bullet.clipboard` for TodoWrite, `folder` for LS,
  `checkmark.seal` for ExitPlanMode, `questionmark.bubble` for
  AskUserQuestion). Fallback: `wrench.adjustable`. AI header uses
  `microbe`/`microbe.fill` (claude-as-agent metaphor).

- **Fill-on-expanded state indicator.** Each `InspectorIcon.Pair` carries
  a `collapsed` and `expanded` SF Symbol name. Where a `.fill` sibling
  exists, the symbol swaps on expand. Where it doesn't (`note.text`,
  `doc.text.magnifyingglass`), the same name is used in both states; the
  appearing body below is the affordance. **Disclosure chevrons dropped
  entirely** — the entire row header HStack is the click target via
  `Button(.plain) { ... }.contentShape(Rectangle())`.

- **Status colors carried by the tool glyph itself** rather than a
  separate dot. Pending = yellow, ok = green, error = red. Mirrors
  claude-devtools' tri-state vocabulary (`BaseItem.tsx:53-60`) but folds
  into a single icon to reduce visual density.

- **AI header has three independent click targets.** Row body toggles
  `aiExpanded` (show/hide thinking + tools). Tokens text toggles
  `tokensExpanded` (compact total `19.3k tokens` ↔ per-bucket breakdown
  `12.3kin · 1.4kout · 5.6kcr · 200cw`, no internal whitespace per user
  feedback). Trailing time/duration text toggles
  `showDurationInHeader` (`HH:mm:ss` ↔ total turn duration). SwiftUI's
  inner `Button` consumes its own tap before the row-level
  `onTapGesture`, so precedence is well-defined.

- **Friendly model names** via `ClaudeModelNameMap.friendlyName(for:)`.
  Ports the mapping from `claude-devtools/src/renderer/utils/modelParser.ts:34-137`:
  `claude-sonnet-4-5-20250929` → `Sonnet 4.5`, `claude-3-5-sonnet-…` →
  `Sonnet 3.5`, etc. Header reads `[microbe] Sonnet 4.5 · …` collapsed.
  Falls through to the raw id for non-claude models.

- **Per-turn duration** computed from JSONL line timestamps —
  `AIChunk.endTime` (last folded message timestamp, set by
  `ClaudeChunkBuilder.PendingAIChunk.lastTimestamp`) minus `startTime`.
  Codex builder leaves `endTime` nil since rollouts have no per-line
  timestamps; the renderer hides the duration display gracefully.

- **Per-tool duration** computed from
  `tool_use.timestamp` → `tool_result.timestamp` delta. Tracked per tool
  id in `PendingAIChunk.toolStartedAt` and stamped into
  `AgentToolCall.durationMs` at result-attachment time.

- **Team-member chip** alongside the typed-subagent chip. Pulls
  `team_name` and `name` from Task input (Claude Code's team feature —
  see claude-devtools' `SubagentResolver.ts:322-326`). The chip prefers
  `name` ("Alice") when present, else uppercases `subagent_type`
  (`general-purpose` → `GENERAL-PURPOSE`).

- **`boldifyKeyValueLines` for tool inputs.** Tool inputs are produced
  as `key: value` lines by `ClaudeChunkBuilder.formatToolInput`. The
  renderer parses each line for a leading identifier-then-colon and bolds
  the key portion via per-run `font: baseFont.bold()` on an
  `AttributedString` (explicit per-run fonts because SwiftUI's outer
  `.font(...)` modifier overrides per-run attributes when fonts are set
  via `inlinePresentationIntent` alone).

- **Markdown rendering attempted then reverted.** Apple's
  `AttributedString(markdown:)` only handles inline syntax (no tables,
  no code blocks, no headings). Partial coverage was visually confusing.
  Embedding cmux's `MarkdownWebRenderer` would add a `WKWebView` per
  chunk row — far too heavy for inline use. Either accept plain text
  inline (current state) or add a Swift Package dependency
  (`swift-markdown-ui`) in a future phase.

- **User color = muted teal-blue (`#7DA9CC`).** Distinct from cyan
  (system), green (ok), yellow (pending), magenta (subagent), red
  (error), claude-orange. Added as `HudPalette.blue` and routed via
  `kindColor(for: .user)`.

- **`AgentInspectorPanel.openDetail(request:)` is a no-op outside
  `.live` mode.** Detail panels do not host a stream; the action is
  guarded so detail-tab rows that somehow surface a "Open detail"
  affordance can't recurse.

### Files added in Phase A++

- `Sources/Panels/AgentInspector/Render/InspectorIcon.swift` — pair
  table for collapsed/expanded SF Symbols, plus per-tool dispatch.
- `Sources/Panels/AgentInspector/Render/ClaudeModelNameMap.swift` —
  friendly model name parser.
- `Sources/Panels/AgentInspector/Detail/AgentInspectorDetailContent.swift`
  — value-typed snapshot + `resolve(request:chunk:)` builder.
- `Sources/Panels/AgentInspector/Detail/AgentInspectorDetailView.swift`
  — static read-only detail view; reuses palette + glyphs.
- `cmuxTests/AgentInspector/ClaudeModelNameMapTests.swift` (9 cases).
- `cmuxTests/AgentInspector/InspectorIconTests.swift` (5 cases).
- `cmuxTests/AgentInspector/AgentInspectorDetailContentTests.swift` (11 cases).

### Files modified in Phase A++

- `Sources/Panels/AgentInspector/Model/AgentChunk.swift` — added
  `AIChunk.endTime: Date?` for per-turn duration.
- `Sources/Panels/AgentInspector/Model/AgentToolCall.swift` — added
  `teamMemberName`, `teamName`, `durationMs` (all optional, nil-default
  for unchanged call sites).
- `Sources/Panels/AgentInspector/Adapters/Claude/ClaudeChunkBuilder.swift`
  — track `lastTimestamp` and per-tool `toolStartedAt`; extract
  `team_name` and `name` from Task tool inputs.
- `Sources/Panels/AgentInspector/Render/ChunkRowSnapshot.swift` —
  rebuilt: per-kind fields, `ExpandableContent` with overflow flag,
  `TokenBreakdown` with both compact-summary and per-bucket labels,
  `ToolCallSnapshot.Status` enum, `AgentKindLabel` enum.
- `Sources/Panels/AgentInspector/Render/ChunkRowView.swift` — rebuilt:
  per-variant private rows (`UserChunkRow`, `AIChunkRow`,
  `SystemChunkRow`, `CompactChunkRow`); per-row `@State` expansion;
  status-colored type icons; row-tap toggles; three-target AI header.
- `Sources/Panels/AgentInspector/Render/HudPalette.swift` — added
  `blue` and `expandedBackground`.
- `Sources/Panels/AgentInspector/AgentInspectorPanel.swift` — dual
  `Mode` (live / detail); `openDetail(request:)` routing.
- `Sources/Panels/AgentInspector/AgentInspectorPanelView.swift` —
  mode-dispatching body; agent-kind plumbing into the snapshot
  factory.
- `Sources/Panels/AgentInspector/Workspace+AgentInspector.swift` —
  `openAgentInspectorDetail(content:fromInspectorPanelId:)` factory.
- `cmuxTests/AgentInspector/ClaudeChunkBuilderTests.swift` — new
  `endTime` assertion (2-second duration on the fixture's AI chunk).
