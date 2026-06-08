# AgentX-ray — TranscriptRoot mutation simplification (handover, 2026-06-08)

## Why this doc exists

This session landed Phase G's type-system unification (commits below)
and uncovered a pure-mechanical simplification that should land before
the remaining sub-commits (G3a/G3b/G5/G4/G6 per the approved plan at
`/Users/I505728/.claude/plans/streamed-cuddling-stream.md`).

**TranscriptRoot.swift today has ~17 functions for an API surface
the user expects to be ~4 (append / mutate / remove / branchOff).
The bloat exists because `AgentEntry.subEntries` and
`SynthesizedEntry.subEntries` are declared `let`, forcing every
mutation to go "extract → reconstruct container with new array →
write back".** Make those fields `internal(set) var`, give
`Entry.subEntries` a setter that case-rebuilds, and ~9 of the 17
functions collapse into chained-subscript expressions.

This doc captures what's landed, the architecture, and the exact
shape of the simplification so a fresh session can implement it
without re-deriving.

---

## What landed in this session

7 commits on `agentxray` (off `78fba329a`):

| Commit | Sub-commit | Topic | Tests |
|---|---|---|---|
| `24a20bf94` | G0 | Inline skill discriminator (single-line tag check) | 143/19 |
| `c9e734eab` | G1 | `TranscriptRoot` infrastructure (paired API) | 155/20 |
| `b36effc9c` | G2a | Dual-write `TranscriptRoot` alongside `ctx.entries` | 155/20 |
| `4bec941d8` | G2b | Switch `transcript()` to `root.subEntries` | 155/20 |
| `5ff1e0bc3` | docs | MIGRATION_PLAN §14 row 19v + handover update | 155/20 |
| `91d9b6da8` | G1.5 | Lift `SubEntry` into `Entry`; collapse paired API | 154/20 |
| `e7d23f387` | G1.5 fix | Drop `ToolEntry.subEntries` | 154/20 |

Approved plan covers G3a / G3b / G5 / G4 / G6 next; this handover
inserts a cleanup step **before** G3a.

---

## Background — what `TranscriptRoot` looks like today

### Unified `Entry` (post-G1.5)

`Sources/CmuxAgentXray/Models/Entry.swift`:

```swift
public enum Entry: Identifiable, Equatable, Sendable {
    case user(UserEntry)
    case agent(AgentEntry)
    case system(SystemEntry)
    case compact(CompactEntry)
    case synthesized(SynthesizedEntry)
    case text(TextSubEntry)         // sub-entry kind, only nested
    case tool(ToolEntry)             // sub-entry kind, only nested
}
```

The "sub-entry only" invariant for `.text` / `.tool` is enforced by
the builder + a runtime assert in `TranscriptRoot.append(parent:entry:)`,
not the type system.

### Container fields (the load-bearing point for this handover)

- `AgentEntry.subEntries: [Entry]` — `public let` (problem)
- `SynthesizedEntry.subEntries: [Entry]` — `public let` (problem)
- `ToolEntry` — no `subEntries` (sub-agent rows will land as
  top-level `AgentEntry` rows in a future commit; out of scope here).

`Entry.subEntries: [Entry]` is a computed projection (getter-only):

```swift
public var subEntries: [Entry] {
    switch self {
    case .agent(let e):       return e.subEntries
    case .synthesized(let e): return e.subEntries
    case .user, .system, .compact, .text, .tool:
        return []
    }
}
```

### `TranscriptRoot` mutation machinery

`Sources/CmuxAgentXray/Models/TranscriptRoot.swift` carries:

- Public API (4): `entry(id:)`, `append(parent:entry:)`, `mutate(id:_:)`, `remove(id:)`.
- Internal hooks for `branchOff` (2): `topLevelIndex(of:)`, `replaceTopLevelRange(_:with:)`.
- Path machinery (2): `path(to:)`, `entryAtPath(_:)` — walk the index
  bottom-up to build a top-down `[Int]` path.
- **Reconstruction machinery (~5)** that disappears under the
  simplification:
  - `mutateAtPath(_:_:)` + `mutateInside(_:path:mutation:)` —
    recursive walk that extracts a child enum case as a copy,
    recurses on the copy's `subEntries`, then writes the modified
    container back to the parent. Required because
    `agentEntry.subEntries[i] = x` doesn't compile when subEntries
    is `let`.
  - Free module-level helpers `withSubEntries(_:_:)`,
    `withAppendedSubEntry(_:_:)`, `withRemovedSubEntryAt(_:index:)` —
    rebuild a container `Entry` (case-match → reconstruct inner
    struct → re-wrap in the case).
- Index plumbing (3): `indexNestedChildren(of:)` (with a redundant
  overload), `collectAllDescendantIds(_:)`, `isSubEntryOnlyCase(_:)`.

The reconstruction machinery is what bloats the file.

---

## The simplification

**Make the inner fields settable from inside the package, and give
`Entry.subEntries` a setter that case-rebuilds.** Then chained
subscripts handle everything Swift can do natively via copy-on-write.

### Changes

**`Sources/CmuxAgentXray/Models/Entries/AgentEntry.swift`:**

```swift
// before
public let subEntries: [Entry]

// after
public internal(set) var subEntries: [Entry]
```

`internal(set)` keeps the external read-only contract — package
consumers (cmux app target) cannot mutate; package-internal code
(TranscriptRoot) can. Same shape preserves `Equatable` / `Sendable`
auto-synthesis. Initializer body stays the same.

**`Sources/CmuxAgentXray/Models/Entries/SynthesizedEntry.swift`:**

Same change to its `subEntries` field.

**`Sources/CmuxAgentXray/Models/Entry.swift` — make `subEntries`
settable:**

```swift
public var subEntries: [Entry] {
    get {
        switch self {
        case .agent(let e):       return e.subEntries
        case .synthesized(let e): return e.subEntries
        case .user, .system, .compact, .text, .tool:
            return []
        }
    }
    set {
        switch self {
        case .agent(var e):
            e.subEntries = newValue
            self = .agent(e)
        case .synthesized(var e):
            e.subEntries = newValue
            self = .synthesized(e)
        case .user, .system, .compact, .text, .tool:
            // Non-container — silently ignore; caller violated the
            // "subEntries are container-only" contract.
            return
        }
    }
}
```

After this, `someEntry.subEntries[i] = newValue` compiles and works
correctly (Swift's `_modify` accessor + COW handle the chain).

### Collapses in `TranscriptRoot.swift`

**Delete entirely:**

- `withSubEntries(_:_:)` (free function)
- `withAppendedSubEntry(_:_:)` (free function)
- `withRemovedSubEntryAt(_:index:)` (free function)

**Simplify drastically:**

- `mutateAtPath` becomes a tight loop using `_modify` accessors:
  ```swift
  private mutating func mutateAtPath(_ path: [Int], _ body: (inout Entry) -> Void) {
      precondition(!path.isEmpty)
      Self.mutateInside(&subEntries, path: path, body: body)
  }

  private static func mutateInside(_ entries: inout [Entry], path: [Int], body: (inout Entry) -> Void) {
      guard let first = path.first, entries.indices.contains(first) else { return }
      if path.count == 1 {
          body(&entries[first])
      } else {
          // With Entry.subEntries settable, this just works:
          mutateInside(&entries[first].subEntries, path: Array(path.dropFirst()), body: body)
      }
  }
  ```

  Same recursive shape as today, but no copy-extract-repack: the
  `&entries[first].subEntries` chain composes through Swift's
  `_modify` accessors all the way down, propagating the in-place
  edit transparently.

- `append(parent:entry:)`'s nested branch can use the chain too:
  ```swift
  // before (uses withAppendedSubEntry):
  mutateAtPath(parentPath) { container in
      container = withAppendedSubEntry(container, entry)
  }
  // after (direct subscript via the settable subEntries):
  mutateAtPath(parentPath) { $0.subEntries.append(entry) }
  ```

- `remove(id:)` for nested entries similarly:
  ```swift
  mutateAtPath(parentPath) { $0.subEntries.remove(at: childIdx) }
  ```

**Keep unchanged:**

- `path(to:)`, `entryAtPath(_:)` — index walks.
- `indexNestedChildren` / `collectAllDescendantIds` — still need to
  maintain the `[EntryID: ParentSlot]` map.
- `topLevelIndex(of:)` / `replaceTopLevelRange(_:with:)` — branchOff hooks.
- Public API (`entry`, `append`, `mutate`, `remove`).

### Cleanup riders worth taking in the same commit

1. **Drop the redundant `indexNestedChildren(of:parent:parentPath:)`
   overload.** Its `parent` and `parentPath` parameters are
   referenced in the body but the value used is always `entry.id`,
   not the parameter. The single-arg version is sufficient.
2. **Inline `isSubEntryOnlyCase(_:)`** at its single call site (the
   DEBUG assert in `append`). It's 3 lines; inlining is cleaner.
3. **Drop `removeIfNeeded` ceremony.** With direct subscript
   mutation, several places that today do "lookup then conditionally
   call helper" become single-line.

After these cuts: function count drops from 17 → ~8.

---

## How the change interacts with downstream sub-commits

The approved plan's remaining sub-commits all benefit from the
simplification:

- **G3a** (`Phase G G3a` per
  `/Users/I505728/.claude/plans/streamed-cuddling-stream.md`):
  the dual-write paths `root.append(parent: skeletonId, entry: ...)`
  and `root.mutate(id: ...) { ... }` are unchanged at the call site.
  The simplification only changes the implementation shape under the
  public API.
- **G3b** flip: same — call sites unchanged.
- **G4**: `branchOff` is in the +BranchOff.swift extension and uses
  `replaceTopLevelRange(_:with:)`, which stays. The new
  `branchOff(after:untilSiblingPredecessor:link:)` design (per the
  plan) lands on top.
- **G5**: independent.
- **G6**: cleanup — the simplification means there's less to clean up.

Verdict: do the simplification AS THE FIRST commit in the next
session, then resume the plan from G3a.

---

## Sequencing for the next session

1. **TranscriptRoot mutation simplification** (this doc) — pure
   refactor, no behaviour change. Tests stay 154/20 green.
2. **G3a** — sub-entry dual-write infrastructure.
3. **G3b** — flip sub-entry source of truth; collapse `PendingTurn`.
4. **G5** — inline FIFO queued-prompt; delete `ClaudeQueuedPromptResolver`.
5. **G4** — per-line rewind detection + pending pool; delete
   `ClaudeBranchResolver`.
6. **G6** — cleanup + docs.

(G3c — drop recursive sidechain — stays deferred. The
"sub-agent-as-AgentEntry" implementation noted in commit `e7d23f387`
is also follow-up and not blocking Phase G.)

---

## Verify-baseline before starting

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline                              # → e7d23f387
swift test --package-path Packages/CmuxAgentXray  # → 154 tests / 20 suites green
```

Then re-read the following files end-to-end:

- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Entry.swift` (108 lines)
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Entries/AgentEntry.swift` (~280 lines)
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Entries/SynthesizedEntry.swift` (~60 lines)
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/TranscriptRoot.swift` (~325 lines)
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/TranscriptRoot+BranchOff.swift` (~50 lines)

Test coverage that exercises the mutation path:

- `Tests/CmuxAgentXrayTests/Models/TranscriptRootTests.swift` —
  append / mutate / remove / branchOff fixture coverage.
- `Tests/CmuxAgentXrayTests/Adapters/Claude/ClaudeTranscriptBuilderTests.swift` —
  end-to-end builder paths that exercise nested mutation.

---

## Cross-doc map

| Doc | Role |
|---|---|
| `/Users/<user>/.claude/plans/streamed-cuddling-stream.md` | **Approved** Phase G plan. G3a/G3b/G5/G4/G6 still pending. |
| `Packages/CmuxAgentXray/docs/next-session-handover.md` | Mid-Phase-G state pin. The "Current state" section at the top documents what landed. NOT updated for the G1.5 + G1.5-fix commits — refresh before starting. |
| `Packages/CmuxAgentXray/MIGRATION_PLAN.md` §14 row 19v | Per-commit ledger (last entry covers G0/G1/G2a/G2b only; G1.5 + G1.5-fix not yet logged). |
| **`Packages/CmuxAgentXray/docs/transcriptroot-mutation-simplification.md`** | **(this doc)** Specific handover for the simplification step. |

If any doc disagrees with the code, the code wins — fix the doc in
the same change.
