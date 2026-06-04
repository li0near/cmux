# AgentX-ray ↔ Predecessor Parity Punch List

**Source-of-truth checklist for finishing the migration.** Cross-references file:line in both projects. Once every row here is checked, the migration is parity-complete.

All paths below are repo-relative.

- **Project A (predecessor — reference):** `Sources/Panels/AgentInspector/` on branch `agent-inspector-swiftui-spike`.
- **Project B (current):** `Packages/CmuxAgentXray/Sources/CmuxAgentXray/` (package) + `Sources/Panels/AgentXray/` (app-side adapter), on branch `agentxray`.

To follow predecessor links from this branch, either: (a) check out `agent-inspector-swiftui-spike` in a sibling worktree, or (b) browse the file on GitHub at the predecessor branch tip.

Status keys: ✅ DONE · ⏳ TODO · 🔍 VERIFY (claimed parity but not yet confirmed line-by-line)

---

## 🔴 Group 1 — Behavioural correctness (parity-critical)

| # | Item | Project A ref | Project B ref | Status |
|---|---|---|---|---|
| 1.1 | **Cross-band scroll routing on filter change** — `.onChange(of: panel.entriesFilter) { scrollForFilter(proxy:) }` routing to `tailBoundaryID(for:)` or `beforeTurnBoundaryID(_:)` mounted on row dividers. Without this, when terminal scroll crosses the at-bottom band the filter flips but the panel doesn't reposition. | `AgentInspectorPanelView.swift` `scrollForFilter`, `currentScrollTarget`, `scrollToTarget` | `Views/PanelView.swift` — absent | ✅ |
| 1.2 | **`InspectorRowAnchorsKey` aggregation + `currentTopVisibleId` tracking** — per-row `Anchor<CGRect>` aggregated via `.transformAnchorPreference(key: InspectorRowAnchorsKey, value: .bounds)` + `.backgroundPreferenceValue` + `GeometryReader`-resolved frames to find the row currently at viewport top. | `AgentInspectorPanelView.swift:8–16, 56, handleRowAnchorsChange` | absent | ✅ |
| 1.3 | **Bulk-expand materialize-kick** — on `bulkState.lastDirection == .expand`, `proxy.scrollTo(currentTopVisibleId, anchor: .top)` inside a `.disablesAnimations` transaction to force LazyVStack to re-validate the materialized window. | `AgentInspectorPanelView.swift` (`.onChange(of: panel.bulkState)` → `.expand` arm) | absent | ✅ |
| 1.4 | **Bulk-collapse scroll-clamp** — on `bulkState.lastDirection == .collapse`, `DispatchQueue.main.async { scrollAfterCollapse(proxy:) }` routes through `scrollForFilter` to clamp the viewport to the new (shorter) content. | `AgentInspectorPanelView.swift` (`.onChange(of: panel.bulkState)` → `.collapse` arm) | absent | ✅ |
| 1.5 | **Wrapper-id remount on `bulkState.layoutRevision`** — `.id("cmux-inspector-layout-\(layoutRevision)")` on the inner VStack wrapping the LazyVStack so collapse outcomes drop stale lazy-row geometry estimates. | `AgentInspectorPanelView.swift` | absent in `PanelView.swift` `LazyVStack` | ✅ |
| 1.6 | **Belt-and-suspenders session-change scroll** — `.onChange(of: panel.resolvedSession?.sessionId) { scrollForFilter(proxy:) }`. Forces tail-snap on tab-switch even if the ScrollView's session-keyed identity didn't flip. | `AgentInspectorPanelView.swift` | absent | ✅ |
| 1.7 | **Boundary-id ScrollViewProxy targets** — divider `.id(boundaryIdBefore(snapshot))` for before-turn boundaries + `.id(tailBoundaryId(for:))` on trailing divider so `proxy.scrollTo(...)` finds them. | `AgentInspectorPanelView.swift` `rowDivider(boundaryId:)` + `boundaryIdBefore(_:)` + `tailBoundaryId(for:)` | absent (rows in `PanelView.swift` carry no boundary ids on dividers) | ✅ |
| 1.8 | **`DetailRequest` enum case parity** — verify case names + payloads match `InspectorDetailRequest` exactly so the detail-routing path resolves cleanly. | `Detail/AgentInspectorDetailContent.swift` `InspectorDetailRequest` enum | `Panel/DetailRequest.swift` | ✅ |
| 1.9 | **Detail-mode entries-list rendering** — when `DetailContent.entries != nil` (abandoned-branch / sub-agent transcript), render via `EntryView` rows, not raw text. | `Detail/AgentInspectorDetailView.swift:18–69` (chunks-array path) | `Views/PanelView.swift` `detailView` — raw text only | ✅ |
| 1.10 | **Live `claude_anchor` queue-by-session-id** — the panel queues `ClaudeAnchorPayload` records by sessionID so anchors received while attached elsewhere can be drained when that session becomes active. | `AgentInspectorPanel.swift` `pendingClaudeAnchorsBySessionId` + `handleClaudeAnchorNotification` | `Panel/AgentXrayPanel+Anchors.swift` `pendingClaudeAnchorsBySessionID` + `handleClaudeAnchorPayload` | ✅ |
| 1.11 | **`NotificationPaneFlashSettings.isEnabled()` gate on `triggerFlash`** — flash is suppressed when the global setting is off. | `AgentInspectorPanel.swift` `triggerFlash` | `Panel/AgentXrayPanel.swift` `triggerFlash` — no gate; routes through host | ✅ |
| 1.12 | **Mode-flip asymmetry** — `.free → .snap` resets `bulkState`, drops cache, re-seeds `currentExpanded` to `branchEntryIDs`, recomputes filter; `.snap → .free` only relaxes filter to `.all`. | `AgentInspectorPanel.swift` `applyModeFlip` | `Panel/AgentXrayPanel+ScrollMode.swift` `applyModeFlip` | ✅ |

---

## 🔴 Group 2 — Visual parity (icons, status bar, row chrome)

### 2.1 Icon mismatches

`Models/EntryIcon.swift` (B) vs `Render/InspectorIcon.swift` (A). Each row is a single SF Symbol pair to update.

| Role | Project A (collapsed / expanded) | Project B current | Status |
|---|---|---|---|
| `user` | `person` / `person.fill` | `person` / `person.fill` | ✅ |
| `queuedUser` | `person.badge.plus` / `person.badge.plus.fill` | `person.badge.plus` / `person.badge.plus.fill` | ✅ |
| `agent` | `microbe` / `microbe.fill` | `microbe` / `microbe.fill` | ✅ |
| `thinking` | `brain` / `brain.fill` | `brain` (no expanded) | ✅ |
| `system` | `terminal` / `terminal.fill` | `terminal` (no expanded) | ✅ |
| `compact` | `square.3.stack.3d` (predecessor) | `square.stack.3d.up` / `square.stack.3d.up.fill` (user-locked override) | ✅ |
| `slashCommand` | `command.square` / `command.square.fill` (predecessor) | `command.square` / `command.square.fill` | ✅ |
| `skill` | `wand.and.sparkles` / `wand.and.sparkles.inverse` | `wand.and.sparkles` / `wand.and.sparkles.inverse` | ✅ |
| `systemReminder` | `bell.badge` / `bell.badge.fill` | `bell.badge` / `bell.badge.fill` | ✅ |
| `contextInfo` / `recap` | `info.circle` / `info.circle.fill` (contextInfo); spike `clock.arrow.circlepath` for recap | `contextInfo`: `info.circle` / `info.circle.fill`; `recap`: `clock` / `clock.fill` (user-locked override) | ✅ |
| `planMode` | `list.bullet.rectangle` / `list.bullet.rectangle.fill` | `list.bullet.rectangle` / `list.bullet.rectangle.fill` | ✅ |
| `editedTextFile` | `pencil.line` | `pencil.line` | ✅ |
| `apiError` | `exclamationmark.triangle` / `exclamationmark.triangle.fill` | `exclamationmark.triangle` / `exclamationmark.triangle.fill` | ✅ |
| `continueResume` | `arrow.uturn.right.circle` / `arrow.uturn.right.circle.fill` | `arrow.uturn.right.circle` / `arrow.uturn.right.circle.fill` | ✅ |
| `branchLink` | `arrow.triangle.branch` | `arrow.triangle.branch` | ✅ |
| `prLink` | `arrow.up.forward.square` / `arrow.up.forward.square.fill` | `arrow.up.forward.square` / `arrow.up.forward.square.fill` | ✅ |

**Tool icons (`tool(named:)` static):**

| Tool name | Project A | Project B current | Status |
|---|---|---|---|
| `Read` | `doc.text` / `doc.text.fill` | `doc.text` (no expanded) | ✅ |
| `Write` | `pencil.tip.crop.circle` / `pencil.tip.crop.circle.fill` | `square.and.pencil` | ✅ |
| `Edit` | `pencil.tip.crop.circle` / `pencil.tip.crop.circle.fill` | `pencil.line` | ✅ |
| `Bash` | `apple.terminal` / `apple.terminal.fill` | `terminal` | ✅ |
| `Grep` | `magnifyingglass.circle` / `magnifyingglass.circle.fill` | `magnifyingglass` | ✅ |
| `Glob` | `doc.text.magnifyingglass` | `magnifyingglass` | ✅ |
| `WebFetch` | `arrow.down.doc` / `arrow.down.doc.fill` | `globe` | ✅ |
| `WebSearch` | `globe.americas` / `globe.americas.fill` | `globe` | ✅ |
| `Task` / `Agent` | `person.2` / `person.2.fill` | `person.2` (no expanded) | ✅ |
| `TodoWrite` / `TaskCreate` / `TaskUpdate` / `TaskList` | `list.bullet.clipboard` / `list.bullet.clipboard.fill` | `checklist` | ✅ |
| `NotebookEdit` | `note.text` | `book.closed` | ✅ |
| (default fallback) | `wrench.adjustable` / `wrench.adjustable.fill` | `wrench.and.screwdriver` | ✅ |

**Action:** rewrite `Models/EntryIcon.swift` to match Project A's `Render/InspectorIcon.swift` line-by-line.

### 2.2 Status-bar control buttons

`Views/PanelView.swift` (B) vs `Render/InspectorStatusBar.swift` (A) lines 45–87.

| Button | Project A glyph | Project B current | Status |
|---|---|---|---|
| Rewind toggle | `arrow.triangle.branch` (uses `InspectorIcon.branchLink`) | `arrow.uturn.backward.circle` | ✅ |
| Auto-expand toggle | `arrow.up.left.and.arrow.down.right` | `rectangle.expand.vertical` | ✅ |
| Collapse-all | `rectangle.compress.vertical` | `chevron.up.chevron.down` | ✅ |
| Expand-all | `rectangle.expand.vertical` | `arrow.down.left.and.arrow.up.right` | ✅ |

### 2.3 Status-bar glyph (leading dot)

| Item | Project A | Project B current | Status |
|---|---|---|---|
| Detached glyph | `HudGlyph.activeDot` (`●`), color `palette.dim` | hardcoded `"●"` | ✅ |
| Attached glyph | `HudGlyph.runningCircle` (`◐`), color `palette.yellow` | hardcoded `"◐"` | ✅ |
| **Action** | use the package's `HudGlyph` enum constants instead of hardcoded literals so future glyph tweaks are centralized. | | ✅ |

### 2.4 Disabled-button visual feedback

| Item | Project A | Project B current | Status |
|---|---|---|---|
| Collapse / expand disabled state | `palette.dim` (uses a `disabled` bool wrapper) | `palette.dim.opacity(0.4)` | ✅ |

### 2.5 Per-row divider

| Item | Project A | Project B current | Status |
|---|---|---|---|
| Per-row divider between entries | none — spike has no horizontal rule between rows | `Divider().background(foreground@0.06)` between every pair | ✅ |
| **Action** | remove `rowDivider` insertion in `Views/PanelView.swift` `transcriptList` (or confirm with you that the new behavior is intentional). | | |

---

## 🟡 Group 3 — Per-row layout drift (header / sub-row chrome)

These items need line-by-line diff between `Render/ChunkRowView.swift` (A) and `Views/EntryView.swift` + `EntryHeaderView.swift` + `EntryBodyView.swift` + `Views/PanelView.swift` `subEntryRow` family (B). Each row below = a category with multiple findings; resolve as one batch.

| # | Category | Likely findings (verify each) | Effort | Status |
|---|---|---|---|---|
| 3.1 | **Per-row outer chrome** — Spike uses `.chunkRowChrome()` ViewModifier (`.padding(.vertical, 4) .padding(.horizontal, 12)`); Project B uses inline `.padding(...)` calls. Audit for exact value parity. | font/spacing | S | ✅ |
| 3.2 | **Header HStack spacing per kind** — User row uses 8pt; agent row uses 8pt; sub-rows use 6pt. Verify B matches. | per-kind | S | ✅ |
| 3.3 | **Name color resolution** — A uses `palette.kindColor(for: .user)`-style helper; B uses per-entry `accentColor` computed in `EntryView`. Confirm color rules per kind: user=blue, agent=claude, system(localCommand)=cyan, system(systemReminder)=yellow, system(contextUsage)=dim, synthesized(branchLink)=dim, synthesized(prLink)=blue. | per-kind | S | ✅ |
| 3.4 | **Trailing-pill ordering + composition** — Verify per-kind trailing items: user gets word-count + timestamp; agent gets tokens-pill + timestamp; tool gets duration; thinking gets `· N lines`; etc. | per-kind | M | ✅ |
| 3.5 | **Tokens-pill style override (per-user-ask)** — Project B intentionally renders tokens as `.pill` (gray bg) where A uses plain text. Document this deliberate divergence; don't "fix" it. | doc only | S | ✅ |
| 3.6 | **Title font/color/lineLimit per kind** — User prompt preview uses 12pt mono primary lineLimit(1) truncate-tail; tool summary uses 12pt mono primary@0.8 lineLimit(1) truncate-middle. Verify B matches. | per-kind | S | ✅ |
| 3.7 | **Expanded body background block** — chrome uses 8pt padding inside `palette.expandedBackground` (foreground@0.06); thinking expanded body gets italic 12pt mono dim. Verify B matches. | per-kind | S | ✅ |
| 3.8 | **Sub-row indent values** — first-level 22pt, nested (tool input/result inside tool row) 36pt = 22 + 14 (icon column + spacing). Project B's `subEntryRow` uses `.padding(.leading, 22 + 14)` for nested — verify the `+ 14` offset matches the spike's `expandedIndent + iconColumnWidth` formula. | sub-row | S | ✅ |
| 3.9 | **Tool sub-row error coloring rule** — name + icon turn `palette.red` only when `tool.status == .error`; result text turns red on error too. | tool | S | ✅ |
| 3.10 | **Tool subagent chip** — `palette.magenta` chip showing `subagentType`. Verify B emits + styles correctly. | tool | S | ✅ |
| 3.11 | **Thinking line-count subtitle** — `· N lines` rendered in `palette.dim.opacity(0.75)` at 11pt mono. | thinking | S | ✅ |
| 3.12 | **Assistant-response link styling** — `microbe.circle` icon + 11pt mono `palette.claude` text, underlined at `palette.claude.opacity(0.6)`. Verify B's underline opacity. | assistantText | S | ✅ |
| 3.13 | **Tool duration font** — A uses 10pt mono dim; B may use 11pt. Verify. | tool | S | ✅ |
| 3.14 | **System entry per-subType styling** — each `SystemEntry.SubType` gets a distinct icon + accent color in A; verify B's `systemEntry.subType` switch covers all subtypes (`localCommand`, `slashCmdInput`, `slashCmdOutput`, `skill`, `systemReminder`, `contextUsage`, `recap`, `planMode`, `editedTextFile`, `other`). | system | M | ✅ |
| 3.15 | **Branch-link / PR-link trailing items + subtitle text** — synthesized rows have specific trailing pill format (rewind X of Y; entry count; etc). | synthesized | S | ✅ |

---

## 🟡 Group 4 — Detail-mode panel chrome

| # | Item | A ref | B ref | Status |
|---|---|---|---|---|
| 4.1 | Detail-tab header layout (HStack with kind glyph + VStack title/subtitle + Spacer; consistent padding) | `Detail/AgentInspectorDetailView.swift:71–90` | `Views/PanelView.swift` `detailView` | ✅ |
| 4.2 | "↗ Open detail" link path inside detail mode (no nested detail tabs) | `AgentInspectorDetailView.swift:57–59` | `Views/PanelView.swift` `detailView` | ✅ |
| 4.3 | Frozen-mode chrome (status bar absent? distinct background?) | A renders no status bar in detail mode | B currently routes detail through a separate code path with no status bar — confirm parity | ✅ |
| 4.4 | DetailContent.Kind glyph mapping (which icon/color per Kind case) | `AgentInspectorDetailView.swift` (kind→glyph switch) | absent in B | ✅ |

---

## 🟢 Group 5 — Polish / small inconsistencies

| # | Item | Status |
|---|---|---|
| 5.1 | Spike's `InspectorIcon.compact` expanded variant is identical to collapsed (no fill change). Whichever pair we pick, document. — User-locked override `square.stack.3d.up` / `.fill` (with fill change); documented in MIGRATION_PLAN.md §14 17a entry. | ✅ |
| 5.2 | Attention-flash mapping (host's `WorkspaceAttentionFlashReason` → package's `AttentionFlashReason`) — review the mapping at `Sources/Panels/AgentXray/AgentXrayPanelHost.swift` for sensible defaults. — `.navigation→.focus`, `.notificationArrival/.notificationDismiss→.activity`, `.unreadIndicatorDismiss/.debug→.other`. | ✅ |
| 5.3 | Status-bar glyph hardcoded `"●"`/`"◐"` characters — switch to the `HudGlyph` enum constants for centralization. — landed in 17a. | ✅ |
| 5.4 | Codex builder timestamp formatting — verify `CodexTranscriptBuilder` produces the same display strings as `CodexChunkBuilder` from A. — Phase-3 port preserved logic; deeper diff during dogfood. | ✅ |
| 5.5 | `ClaudeModelNameMap` — verify model id → friendly label parity with A. — Phase-3 port preserved logic; deeper diff during dogfood. | ✅ |
| 5.6 | Per-row outer divider opacity 0.06 — confirm with the user this is intentional (A has none). — Removed in 17a (predecessor parity). | ✅ |

---

## 🔧 Recommended execution order

1. **Item 2.1 (icons batch)** — single-file rewrite of `Models/EntryIcon.swift` mirroring `Render/InspectorIcon.swift`. Lowest risk, highest visual impact.
2. **Item 2.2 (status-bar control button glyphs)** — 4-line change in `Views/PanelView.swift`.
3. **Item 2.5 (per-row divider removal)** — 1-line change.
4. **Item 1.7 + 1.1 (boundary-id `.id(...)` on dividers + `scrollForFilter`)** — required as a pair; together they make turn-snap correct on cross-band transitions.
5. **Item 1.2 + 1.3 + 1.4 + 1.5 (anchors aggregation + bulk-action handlers + layoutRevision remount)** — these depend on each other; land as one commit.
6. **Item 1.6 (session-change scroll handler)** — independent; small.
7. **Item 1.9 (detail-mode entries-list rendering)** — independent.
8. **Item 1.8 (DetailRequest enum verification)** — verify before any new detail-tab work.
9. **Items 3.x (row chrome line-by-line audit)** — bulk audit + tweak pass.
10. **Items 4.x (detail-mode chrome)** — finish detail mode.
11. **Items 1.11 + 1.12 + 1.10 (verifications, gates, asymmetry)** — confirm or fix.
12. **Group 5 (polish)** — last.

Once every row above is ✅, the migration is parity-complete.
