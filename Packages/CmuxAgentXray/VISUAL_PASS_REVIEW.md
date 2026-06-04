# Visual-pass execution spec (locked)

This is the agreed-on spec for the visual-parity commit. Every section here is signed off; the next commit lands these changes.

---

## §0 — PREREQUISITE: rename `AgentTurn` → `AgentEntry` (✅ landed as its own commit)

**Status:** ✅ done (commit `17pre`).

The user's original instruction during Phase 2 was that **everything derives from "Entry"** — `User, System, Agent, etc.` — but the implementation shipped `UserEntry` / `SystemEntry` / `CompactEntry` / `SynthesizedEntry` alongside `AgentTurn`. The asymmetry was a unilateral deviation (logged in the prior MIGRATION_PLAN.md §17 as a fabricated Q&A) that contradicted the user's explicit umbrella instruction. Fixed mechanically before the visual-pass commit so all the new view files land under the correct name.

**Sweep — `AgentTurn` → `AgentEntry` everywhere:**

| Site | Old | New |
|---|---|---|
| File | `Models/Entries/AgentTurn.swift` | `Models/Entries/AgentEntry.swift` |
| Struct decl | `public struct AgentTurn` | `public struct AgentEntry` |
| Umbrella case | `Entry.agent(AgentTurn)` | `Entry.agent(AgentEntry)` |
| Nested types | `AgentTurn.SubEntry`, `AgentTurn.TokenUsage`, `AgentTurn.SubEntry.Status` | `AgentEntry.*` (same nested names; parent renamed) |
| `TurnAnchor.agentTurnID` field | `var agentTurnID: String?` | `var agentEntryID: String?` |
| `TurnAnchorStore.pairAgentTurn(...)` | method name | `pairAgentEntry(userEntryID:agentEntryID:)` |
| `Panel/AgentXrayPanel+Anchors.swift` `pairTurnAnchorsToAgentTurns()` | method name | `pairTurnAnchorsToAgentEntries()` |
| `ThinkingEntry.parentTurnID` / `AssistantTextEntry.parentTurnID` | field name | `parentEntryID` |
| Doc set (`MIGRATION_PLAN.md`, README, this file) | type-name references | replace `AgentTurn` → `AgentEntry`; the §17 "AgentRow vs AgentTurn" Q&A line was deleted (it was a fabrication, not a real user decision) |

**Doc-comment prose intentionally NOT renamed:** "agent turn" as the conversational concept (one back-and-forth in a Claude session) stays as "turn" — only the **type-name** `AgentTurn` flipped. Phrases like "per-turn aggregate", "this turn", "(in-progress) turns", "the turn's subEntries", "stop_reason from the last assistant message folded into this turn" all preserve the semantic meaning.

**What legitimately stays "Turn":**
- `TurnAnchor` (struct) — a turn-anchor records the conversational *turn boundary* (user-prompt + agent-response pairing). "Turn" here is the conversational concept, not a type name.
- `TurnAnchorStore` — same.
- `pairTurnAnchorsToAgentEntries` — "Turn" for the anchor concept, "Entry" for the type.
- `perTurnDurationMs` / `recordTurnStart` — conversational-turn semantics, not type references.

**Already-correct (no change):** `streamingEntryID` on `AgentXrayPanel` already follows the entry naming; leave alone.

**Verification:** after the rename commit, `git grep -wn "AgentTurn"` returns zero hits in code; build green; tests 21/21 green.

---

## §1 — Status glyph (3 mutually-exclusive states)

`circle.fill` SF symbol, three colors, top-down precedence:

```
1. resolvedSession == nil || stream.error != nil   →  RED      "Detached"  /  "Stream error: <msg>"
2. stream.entries.isEmpty                          →  YELLOW   "<attach-stage label>"
3. else                                            →  GREEN    "attached <kind> <session…>  <cwd>"
```

Stream-error message replaces the status text (full readable copy in the empty-state body so long messages aren't clipped).

**`AttachStage` enum** drives the yellow-state label — landed as a follow-up commit (not in the visual-parity commit):

```swift
enum AttachStage {
    case idle
    case awaitingSession
    case sessionHooked(sessionID: String)
    case locatingTranscript
    case streamingNoEntries
    case streaming(turnCount: Int, tokenTotal: Int)   // future
}
```

---

## §2 — Icon table

`Models/EntryIcon.swift` rewrite. Bold rows = changes from current.

### Canonical role icons

| Token | Target |
|---|---|
| `.user` | `person` / `person.fill` |
| `.queuedUser` | `person.badge.plus` / `person.badge.plus.fill` |
| `.agent` | `microbe` / `microbe.fill` |
| **`.thinking`** | **`brain` / `brain.fill`** (was `brain` only) |
| **`.system`** | **`terminal` / `terminal.fill`** (was `terminal` only) |
| **`.compact`** | _verify spike, then mirror_ |
| **`.slashCommand`** | _verify spike, then mirror_ |
| **`.skill`** | **`wand.and.sparkles` / `wand.and.sparkles.inverse`** |
| **`.systemReminder`** | **`bell.badge` / `bell.badge.fill`** |
| **`.contextInfo`** | **`info.circle` / `info.circle.fill`** |
| **`.recap`** | _verify spike, then mirror_ |
| **`.planMode`** | **`list.bullet.rectangle` / `list.bullet.rectangle.fill`** |
| **`.editedTextFile`** | **`pencil.line`** |
| **`.apiError`** | **`exclamationmark.triangle` / `exclamationmark.triangle.fill`** |
| **`.continueResume`** | **`arrow.uturn.right.circle` / `arrow.uturn.right.circle.fill`** |
| `.branchLink` | `arrow.triangle.branch` |
| **`.prLink`** | **`arrow.up.forward.square` / `arrow.up.forward.square.fill`** |

### Tool icons (`tool(named:)`)

| Tool | Target |
|---|---|
| **`Read`** | **`doc.text` / `doc.text.fill`** |
| **`Write`** | **`pencil.tip.crop.circle` / `pencil.tip.crop.circle.fill`** |
| **`Edit`** | **`pencil.tip.crop.circle` / `pencil.tip.crop.circle.fill`** |
| **`Bash`** | **`apple.terminal` / `apple.terminal.fill`** |
| **`Grep`** | **`magnifyingglass.circle` / `magnifyingglass.circle.fill`** |
| **`Glob`** | **`doc.text.magnifyingglass`** |
| **`WebFetch`** | **`arrow.down.doc` / `arrow.down.doc.fill`** |
| **`WebSearch`** | **`globe.americas` / `globe.americas.fill`** |
| **`Task` / `Agent`** | **`person.2` / `person.2.fill`** |
| **`TodoWrite` family** | **`list.bullet.clipboard` / `list.bullet.clipboard.fill`** |
| **`NotebookEdit`** | **`note.text`** |
| **(default)** | **`wrench.adjustable` / `wrench.adjustable.fill`** |

### Status-bar control buttons

| Button | Target |
|---|---|
| Rewind | `arrow.triangle.branch` (reuses `EntryIcon.branchLink.collapsed`) |
| Auto-expand | `arrow.up.left.and.arrow.down.right` |
| Collapse-all | `rectangle.compress.vertical` |
| Expand-all | `rectangle.expand.vertical` |

---

## §3 — `Layout.swift` (semantic tokens)

Spacing / Padding / Indent are derived where the relationship matters; sibling-pairs (e.g., `subRowIconWidth` ↔ `subRowIconText`) are hardcoded since they read naturally side-by-side.

```swift
enum Layout {
    enum Spacing {
        static let rowIconText: CGFloat    = 8     // top-level row HStack: icon ↔ text
        static let subRowIconText: CGFloat = 6     // sub-row HStack
        static let tight: CGFloat          = 4     // inside-pill segments
        static let verticalStack: CGFloat  = 4     // row internal vertical gap
    }

    enum Padding {
        static let horizontal: CGFloat        = 12   // outer container left/right
        static let pillHorizontal: CGFloat    = 6    // inside each pill
        static let expandedBodyBlock: CGFloat = 8    // inside the gray body block
        static let topLevelRowGap: CGFloat    = 4    // vertical spacing between consecutive rows
    }

    enum Metric {
        static let rowIconWidth: CGFloat    = 14    // SF symbol visual width at Row.name
        static let subRowIconWidth: CGFloat = 12    // matches SubRow.name
    }

    enum Indent {
        // Sub-row icon aligns with parent row's first text character.
        static var subRow: CGFloat       { Metric.rowIconWidth + Spacing.rowIconText }
        // = 22

        // Nested content (tool input/result inside tool sub-row) aligns just past the sub-row's icon.
        static var nestedSubRow: CGFloat { subRow + Metric.subRowIconWidth }
        // = 34
    }

    enum Height {
        static let statusBar: CGFloat  = 32
        static let pill: CGFloat       = 20
        static let iconButton: CGFloat = 20    // hit frame; icon font itself stays at its semantic size
    }

    enum Stroke {
        static let pill: CGFloat = 0.5    // pill border line width
    }

    enum CornerRadius {
        static let pill: CGFloat              = 4
        static let expandedBodyBlock: CGFloat = 4
    }

    /// Four levels — every other variant collapses into one of these.
    /// Pill stroke uses `dim`; assistant-response link underline uses `dim`.
    enum Opacity {
        static let bgWash: Double  = 0.06    // expanded body gray block
        static let divider: Double = 0.15    // top divider above transcript
        static let dim: Double     = 0.55    // secondary text, pill borders, link underline
        static let detail: Double  = 0.75    // tertiary text on dim (sub-row line counts, tool summary)
    }
}
```

**Why 4 opacity levels (not 7):** earlier I had 0.45 / 0.55 / 0.60 / 0.75 / 0.80 / 0.06 / 0.15 — visually indistinguishable above ~0.5 in monospace text. Collapsed to 4 levels: bg / divider / dim / detail. Pill stroke uses `dim`; link underline uses `dim`; tool summary uses `detail`.

**Note on `Layout.Padding.topLevelRowGap`:** since rows have intrinsic height (multi-line bodies), this is the LazyVStack's `spacing:` parameter — not a manual padding.

**Vertical-centering paddings dropped entirely.** Containers with fixed heights (`statusBar: 32`, `pill: 20`, `iconButton: 20`) center content via SwiftUI default; no `.padding(.vertical, …)` calls survive on those.

**Disabled-button feedback:** plain `palette.dim` (no extra `.opacity(0.4)`).

**Per-row hairline divider:** removed — predecessor has none.

---

## §4 — `Typography.swift` (per-view groups)

Four groups: status bar, top-level row, sub-row, detail panel. Icon size in each group reuses the matching `name` size (without the semibold weight, so SF Symbols don't render bold).

```swift
enum Typography {
    enum StatusBar {
        static let title       = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let pillLabel   = Font.system(size: 11,                  design: .monospaced)
        static let icon        = Font.system(size: 11)   // glyph + control buttons
    }

    enum Row {                                            // top-level entries
        static let name        = Font.system(size: 12, weight: .semibold, design: .monospaced)
        static let summary     = Font.system(size: 12,                    design: .monospaced)
        static let meta        = Font.system(size: 11,                    design: .monospaced)  // label / pill / timestamp
        static let icon        = Font.system(size: 12)   // matches name size; no weight
    }

    enum SubRow {                                         // -1 from Row across the board
        static let name        = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let summary     = Font.system(size: 11,                    design: .monospaced)
        static let meta        = Font.system(size: 10,                    design: .monospaced)  // line counts / tool duration
        static let icon        = Font.system(size: 11)   // matches name size
    }

    enum DetailPanel {
        static let heading     = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let subtitle    = Font.system(size: 11,                    design: .monospaced)
        static let body        = Font.system(size: 12,                    design: .monospaced)
    }
}
```

Italic body for the expanded thinking sub-row is `Typography.Row.summary.italic()` at the call site.

---

## §5 — Hover style (every interactive surface)

`Views/Helpers/HoverBars.swift`:

```swift
struct HoverBars: ViewModifier {
    @State private var hovering = false
    let palette: HudPalette

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top)    { bar(visible: hovering) }
            .overlay(alignment: .bottom) { bar(visible: hovering) }
            .onHover { hovering = $0 }
    }

    private func bar(visible: Bool) -> some View {
        Rectangle()
            .fill(palette.primary)
            .frame(height: 1)
            .opacity(visible ? Layout.Opacity.dim : 0)
            .animation(.easeOut(duration: 0.12), value: visible)
    }
}

extension View {
    func hoverBars(palette: HudPalette) -> some View {
        modifier(HoverBars(palette: palette))
    }
}
```

Applied uniformly to every interactive surface — frame-less (token pill, word-count pill, agent-header timestamp, scroll-mode pill, assistant-response link) **and** framed (the four status-bar control buttons + status glyph if it ever becomes clickable).

Animation duration 0.12s for snappy feedback.

---

## §6 — Misplaced code (extract / move / delete)

| Currently in | Move to | Reason |
|---|---|---|
| `Views/PanelView.swift` lines 49–168 (status bar + 4 control buttons + scroll-mode pill) | `Views/StatusBarView.swift` + `Views/StatusBarPill.swift` | own component |
| `Views/PanelView.swift` lines 245–449 (`agentTurnRow` + `subEntryRow` + `thinkingRow` + `toolRow` + `assistantResponseRow`) | `Views/AgentTurnRowView.swift` + `Views/SubRow/{Thinking,Tool,AssistantResponse}RowView.swift` | per-kind concerns |
| `ClaudeTranscriptBuilder` static methods `formatTokenTotal` / `userPromptPreview` / `wordCount` | `Adapters/Common/TokenFormatter.swift` + `Adapters/Common/PromptTextFormatter.swift` | agent-agnostic utilities |
| `PanelView.expandedIndent` static | `Layout.Indent.subRow` | global layout token |
| `Views/Helpers/EntryChrome.swift` | **delete** | unused; semantics are wrong |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/CmuxAgentXray.swift` (`AgentXrayModule.moduleName` marker) | **delete** | not load-bearing |
| `Tests/CmuxAgentXrayTests/CmuxAgentXraySmokeTests.swift` `moduleMarker` test | **delete** | depends on the marker |

---

## §7 — Naming changes

| From | To | Reason |
|---|---|---|
| `CmuxAgentXrayPanelView` | `TranscriptView` | the type *is* the live transcript display |
| `EntryView.accentColor` (computed property) | `kindAccentColor` | not a SwiftUI environment override |
| `ExpansionToggle.entryChevron(entryID:)` | `ExpansionToggle.entry(id:)` | "chevron" is implementation detail (no chevron rendered) |
| `rowDivider` / `hairlineDivider` / `topDivider` (three names in PanelView) | one `dividerLine(opacity:)` helper in `Views/Helpers/DividerLine.swift` | three names for the same shape |

---

## §8 — Files added / changed / deleted (final manifest)

**New:**
- `Views/Layout.swift`
- `Views/Typography.swift`
- `Views/StatusBarView.swift`
- `Views/StatusBarPill.swift`
- `Views/AgentTurnRowView.swift`
- `Views/SubRow/ThinkingRowView.swift`
- `Views/SubRow/ToolRowView.swift`
- `Views/SubRow/AssistantResponseRowView.swift`
- `Views/Helpers/HoverBars.swift`
- `Views/Helpers/DividerLine.swift`
- `Adapters/Common/TokenFormatter.swift`
- `Adapters/Common/PromptTextFormatter.swift`

**Renamed:**
- `Views/PanelView.swift` → `Views/TranscriptView.swift`

**Changed (in place):**
- `Models/EntryIcon.swift` — full icon rewrite (§2)
- `Views/EntryHeaderView.swift` — Typography.Row.* + Layout.Spacing.rowIconText
- `Views/EntryBodyView.swift` — Typography.Row.* + Layout.Padding.expandedBodyBlock
- `Views/EntryView.swift` — `accentColor` → `kindAccentColor`
- `Views/HudPalette.swift` — keep (kind-color rules unchanged)
- `Adapters/Claude/ClaudeTranscriptBuilder.swift` — formatter methods removed (delegate to Adapters/Common/)
- `Panel/AgentXrayPanel+Expansion.swift` — `ExpansionToggle.entryChevron` → `.entry`
- `Sources/Panels/PanelContentView.swift` (cmux app side) — references `TranscriptView`

**Deleted:**
- `Views/Helpers/EntryChrome.swift`
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/CmuxAgentXray.swift`
- `Tests/CmuxAgentXrayTests/CmuxAgentXraySmokeTests.swift` `moduleMarker` test (file kept; only the test removed if other tests live there)

---

## §9 — Out of scope for this commit (follow-ups)

- **`AttachStage` feature** (status text driven by attach progress + streaming-error rendering) — separate commit immediately after the visual-parity commit lands.
- **Group 1 from `PARITY_PUNCH_LIST.md`** — behavioural correctness items: `scrollForFilter` cross-band routing, `InspectorRowAnchorsKey` aggregation, bulk-collapse / bulk-expand handlers, `layoutRevision` remount, session-change scroll handler, boundary-id `.id(...)` on row dividers, detail-mode entries-list rendering. These are a separate batch after AttachStage.

---

## §10 — Sign-off

All §1–§8 are locked. Visual-parity commit lands as one batch. Follow-up commits land per §9.

If anything in this doc still surprises you, flag it before I start writing code.
