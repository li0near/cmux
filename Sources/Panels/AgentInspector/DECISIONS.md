# Agent Inspector — Decision Log

Active design models, hard-won lessons, and don't-re-walk lists.
Settled phase-by-phase narratives live in git history (`git log
--oneline cmuxTests/AgentInspector/ Sources/Panels/AgentInspector/`)
and are not duplicated here. The canonical handover is
`~/.claude/plans/crystalline-seeking-firefly.md`. `FORK_NOTES.md`
holds the upstream-touch ledger only.

---

## Active design models

### Snapshot-driven, cascade-free row updates

Bulk-managed expansion is **not** per-row `@State`. The panel owns
the source of truth — `bulkState: BulkExpansionState` (stage + tick +
last direction) and `expansionOverrides: ExpansionOverrides` (a
value-type dict keyed with `kind:` prefixes). The panel view's body
resolves the pair into per-row booleans (`chunkBodyOpen`,
`aiHeaderOpen`, `thinkingOpen`, per-tool `expanded`) via
`ChunkRowSnapshot.ExpansionResolver`, baked into the snapshot before
row construction.

Result: one publish on the panel → one synchronous body pass → all
rows update in the same frame. No `.onChange(of: bulkState)`
cascade, no off-screen drift, no LazyVStack height-estimate race
on row expansion state. Off-screen rows that scroll into view later
read the resolved snapshot directly and render correctly without any
`.onChange`-driven fixup.

`AIChunkRow` retains `@State` for `tokensExpanded` and
`showDurationInHeader` because those are independent of bulk
semantics — local UI toggles only.

### `ExpansionOverrides` invariant

Entries in the dict are **always different from the stage default**.
`set(key:value:defaultValue:)` drops the entry when the new value
equals the default. From this single invariant:

- `hasExpandFiddle` = any `true` entry (above-default).
- `hasCollapseFiddle` = any `false` entry (below-default).

No sticky flags, no reset edge cases. The pure-function decisions
`ExpansionOverrides.collapseOutcome(stage:overrides:)` /
`expandOutcome(stage:overrides:)` return one of `.noop`,
`.advance(to:)`, `.snapBack` — `AgentInspectorPanel.collapseAll()` /
`expandSnap()` are thin wrappers that dispatch to
`applyBulkOutcome(_:direction:)`.

### Snap-back-first, direction-aware

If the user has fiddled rows in the OPPOSITE direction since the
last bulk action, the next bulk click rolls back the fiddles
(re-applies the current stage) instead of advancing. Symmetric for
both directions but asymmetric in feel — `Expand` from a fiddled
state advances directly to `fullyExpanded`; `Collapse` from a
fiddled state rolls back the fiddles first, then a second click
advances.

Terminal-stage clicks with no overrides are true no-ops — no
publish, no tick increment, no scroll reset.

### Snapshot-boundary policy (hard rule)

Rows below the LazyVStack hold **no observable references**. No
`@ObservedObject`, `@EnvironmentObject`, `@StateObject`, or stored
weak refs. `ChunkRowView` takes only `ChunkRowSnapshot` (value
type), `HudPaletteToken` (value), `streamingAIChunkId: String?`,
and two stable closures (`onOpenDetail`, `onToggleExpansion`). The
custom `==` ignores closures so SwiftUI can short-circuit body
re-evaluation across closure churn. See
`Sources/Panels/AgentInspector/Render/ChunkRowView.swift:28-32`.

All chunk → snapshot transformations happen in
`AgentInspectorPanelView`'s body as a single `let` projection —
never inside any row's body (CLAUDE.md rule: no state mutation in
view computations).

### Universal pixel-offset clamp model (verbal spec, NOT shipped)

> If after a state change `offset + viewport > contentHeight`, snap to chunks' bottom. Else leave the user's offset alone.

User's stated correctness model for blank-screen avoidance. Needs an accurate `contentHeight`, which `LazyVStack` does not provide ("Hard-won lessons → LazyVStack height estimation is unreliable") and which AppKit could provide but has been ruled out (don't-re-walk #4). The model **won't ship** in its full form; the partial mitigation in "Mitigations currently shipped" is the practical compromise.

---

## Don't-re-walk list

All approaches in this section have been tried, dogfood-tested,
and rejected. Each entry includes the failure mode so the next
session doesn't re-walk for the same reason. The two clusters are
chronologically distinct — they failed against different bug
classes — but listed together for the next reader's convenience.

### Flash class (Phase D, shipped fix in `5c37d9b72`)

- **`defaultScrollAnchor(.bottom)`** initial-render alignment
  (`58ca48644`, reverted in `b241ee532`) — pinned tools at viewport
  bottom on initial render, wrong UX. Today's session re-tested
  this modifier for a different failure mode; see the second
  cluster below.
- **Single-height bottom sentinel** (`1ad6df443`) — visually ugly per user.
- **Dividers between rows + no bottom padding** (`b7db64e27`) —
  removed the trailing divider the user wanted visible.
- **Bug B v1 (anchors-empty → stay on latest)** (in `bc8f7ada4`,
  reverted by `1654eba9a`) — killed the off-bottom free-scroll.
- **Option A: always render all chunks; filter as scroll target** —
  eliminated flash but lost snap mode's visual constraint
  (latest turn's chunks isolated).

### Blank-screen-on-shrink class (post-cascade-refactor)

**Status: mitigation shipped, bug not currently observable in user dogfood.**
See "Mitigations currently shipped → Unconditional `proxy.scrollTo(lastChunkId, anchor: .bottom)` on collapse" below.

The systematic failure mode is that SwiftUI's `LazyVStack` does not
guarantee accurate geometry for off-screen rows. From Apple's
"Creating Performant Scrollable Stacks"
(`developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks`,
fetched 2026-05-26): "Lazy stacks trade some degree of layout
correctness for performance, because the system only calculates the
geometry for subviews as they become visible." After state changes
shrink rows, off-screen contributions to `contentSize.height` lag —
any clamp predicated on the reported total (manual or
framework-provided) lands wrong. Empirically observed in this
codebase via don't-re-walk #1 (mirrored `contentSize.height` into
`@State` through `.onScrollGeometryChange`; the value was visibly
stale after row-shrink).

1. **Geometry clamp via `.onScrollGeometryChange`** (macOS 15+).
   Mirrored `contentOffset.y / contentSize.height /
   containerSize.height` into `@State`; on state-change
   `.onChange` handlers, deferred-async, checked
   `viewportBottom > contentHeight + 1` and `proxy.scrollTo`
   the last chunk. Reads stale `contentHeight`.
2. **`.scrollPosition(id: $scrolledID, anchor: .top` / `.bottom)`**.
   Track topmost/bottommost visible chunk; SwiftUI's
   "keep visible across content size changes" was supposed to
   anchor that chunk. The binding updates from the same stale
   layout view.
3. **Eager `VStack` (no LazyVStack)**. Eliminated the bug; cost
   was a dramatic perf regression on initial load and scrolling
   for ~200 chunks fully expanded. Not viable.
4. **`List(.plain)` (NSTableView-backed)**. Heights are real,
   but small-content alignment defaults to top with blank below
   (regression for snap mode), and initial-render lag was
   substantial — confirmed unacceptable by user. A hand-rolled
   `NSViewRepresentable + NSTableView + NSHostingView<ChunkRowView>`
   would inherit the same eager-measurement lag (the cost is in
   `NSHostingView.intrinsicContentSize` per row, not in `List`'s
   trimmings). AppKit migration is **ruled out** on this basis.
5. **`.defaultScrollAnchor(.bottom)`** (single-arg, all roles).
   Worked for collapse-from-bottom but broke snap-mode
   top-alignment — small-content `.alignment` role inherits the
   `.bottom` anchor and pins chunks at viewport bottom.
   *Different* failure mode from the first-cluster rejection of
   the same modifier.
6. **`.defaultScrollAnchor(.bottom, for: .sizeChanges)` +
   `.defaultScrollAnchor(.top, for: .alignment)`** (macOS 15+;
   Apple's exact chat pattern). The size-change anchor fights
   manual scrolling, and explicit `proxy.scrollTo` calls (filter
   transitions, snap-back) race against it.
7. **Universal pixel-offset clamp wired to `panel.bulkState`,
   `panel.expansionOverrides`, `panel.rewindVisibility`** with
   per-event handlers — the user's stated correctness model.
   Failed for the same reason as (1) — stale `contentHeight`.
8. **Unconditional `proxy.scrollTo(lastChunkId, anchor: .bottom)` on collapse** (this session, kept as the shipped mitigation — see "Mitigations currently shipped"). Reduces blank-screen frequency substantially; original residual described above is **not currently observable** in user dogfood post-mitigation. Confirms empirically that targeting a specific row helps (because `ScrollViewReader.scrollTo(rowId, anchor:)` benefits from the lazy stack's local correctness near the target row), even though it doesn't fully escape the documented "geometry only calculated for subviews as they become visible" trade-off in pathological cases.

For Apple-doc citations consult `developer.apple.com` directly via the JSON DocC endpoint (`developer.apple.com/tutorials/data/documentation/<path>.json`); see `AGENT_WORKFLOW.md` source-priority section. The `docs/apple-swiftui-scroll/` snapshot folder is stale-reference-only.

---

## Hard-won lessons (apply by default)

### Closure-staleness in `.onChange` handlers

`.onChange` handlers in `AgentInspectorPanelView.swift` that
captured the body's `let snapshots` projection by closure could
read one body-invocation behind on rapid state change. Resolved by
having `isFollowingLiveTail()` read `panel.stream.chunks` and
re-derive the visible chunk set live inside the closure. Future
`.onChange` handlers must read panel state directly, not capture
body projections.

### Snapshot-boundary policy

Any `ObservableObject` reference held below the LazyVStack
re-invalidates every row on any orthogonal `@Published` change and
thrashes `LazyLayoutViewCache` (root cause of the cmux Sessions
panel CPU pegging — issue #2586). Rows must hold value types and
stable closures only. Custom `Equatable` enables SwiftUI to skip
body re-evaluation across closure churn.

### LazyVStack height estimation is unreliable

The reported `contentHeight` includes estimated heights for
un-materialized rows; estimates lag reality after state changes
that shrink visible-row heights. Don't predicate scroll math on
that value. Either keep all rows materialized (eager VStack — perf
problem), use a non-estimating list primitive (`NSTableView` —
ruled out for cmux due to initial-render lag, see don't-re-walk
#4), or accept the imprecision and implement scroll behavior that
doesn't depend on `contentHeight`.

---

## Mitigations currently shipped

### Unconditional `proxy.scrollTo(lastChunkId, anchor: .bottom)` on collapse

**File**: `Sources/Panels/AgentInspector/AgentInspectorPanelView.swift` — `scrollToBottom(proxy:)` + `visibleLastSnapshotId()` helper. Shipped in `c9e7c7146`.

The bulk-collapse-direction handler and the live-tail follow handler call `proxy.scrollTo(visibleLastSnapshotId(), anchor: .bottom)` instead of targeting the LazyVStack container's `.id(...)` sentinel. `visibleLastSnapshotId()` mirrors `isFollowingLiveTail()`'s visibility projection, read live from `panel` state inside the closure (closure-staleness rule, above).

**Why**: targeting the container's bottom asks SwiftUI to compute the LazyVStack's total `contentSize.height` — which carries the documented layout-correctness trade-off. Targeting a specific row asks `ScrollViewReader` to position THAT row at the viewport bottom, sidestepping the global calculation.

**Outcome**: blank-screen-on-collapse appears **much less frequently**. `→ .fullyCollapsed` did not reproduce in user dogfood; `→ .topLevelExpanded` was occasionally observed mid-`.fullyExpanded → .topLevelExpanded` immediately post-ship, but is **not currently observable** in subsequent dogfood — may have been further reduced by other changes along the way.

**Escalation if the bug returns**: `.id(...)` remount of the LazyVStack on collapse-direction publishes — out of scope unless residual returns. AppKit migration permanently ruled out per don't-re-walk #4.

### Chunk-computed side cache (per-chunk `makeExpandable` + word-counts)

**File**: `Sources/Panels/AgentInspector/Render/ChunkComputedCache.swift` — `ChunkComputedFields` value type (per-kind substructs) + `ChunkContentSignature` (cheap UTF-8 byte fingerprint) + `ChunkComputedCache` (`@MainActor final class`). Plumbed via a new `computed: ChunkComputedFields?` parameter on `ChunkRowSnapshot.from(...)`. Shipped in `18b45861c`.

Owned by `AgentInspectorPanel` as `let computedCache = ChunkComputedCache()`; reset on `handleSessionChange`.

**Why**: every panel-body invocation rebuilds `ChunkRowSnapshot` for each visible chunk, running line-split + UTF-8 byte walk inside `makeExpandable` for every content section, plus `trimmed.split { ... }.count` word-counts. These are deterministic per `(chunk content, displayMode)`; caching them keyed by `(chunk.id, signature-bytes, displayMode)` eliminates the repeated work without changing snapshot output.

**Outcome**: addresses the suspected cause of plan §5.E (initial freeze on first at-bottom-band crossing), which is currently non-observable. No behavioural change visible to the user; the cache is a perf scaffold ready for when the freeze returns or for sessions large enough to make the per-frame recompute matter.

**Subsumes** the previously-listed "Snapshot caching keyed by `(chunk-id, expansion-resolved-state)`" idea: this design caches only the `(chunk content, displayMode)`-deterministic bits, orthogonal to expansion state. Expansion-state changes still rebuild the snapshot but read cached `makeExpandable` results.
