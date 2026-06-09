# AgentX-ray e2e test framework — design + implementation handover

**Created:** 2026-06-09 · **Owner:** Ethan + sessions · **Status:** designed, not yet implemented

This doc is the implementation handover for an e2e test framework
covering the AgentX-ray Claude transcript builder. The design has
gone through one round of iteration with the user; **all open
questions are resolved**. The next session can implement it directly
without re-litigating choices.

---

## Goal

Close the silent-corruption surface of the post-G6 single-pass
dispatcher. Today the new design relies on corpus-survey claims that
have already been wrong twice (single-child pool invariant; slash-cmd
doesn't consume queued prompts). The unit-test layer (162 tests in
24ms, all heredoc-string fixtures) catches per-feature regressions
but not session-shape variation. We need a tier above that pins
real-world scenarios as fixtures AND scans live corpus for invariant
violations.

## Three-layer architecture

### Layer 1 — Hand-authored fixture suite (always-on, deterministic)

Per-scenario fixtures committed in-tree. Each scenario is a
directory with `input.jsonl` + `README.md` + a sibling Swift test
file. Tests load + dispatch + assert on `[Entry]` shape. Always
runs.

### Layer 2 — Corpus invariant suite (auto-runs when corpus exists)

Walks the user's `~/.claude/projects/` if present, picks heterogeneity-
covering sessions, asserts structural invariants. Skips cleanly when
the directory doesn't exist (CI, fresh-clone developer machine).
**No env flag** — presence-based gating only.

### Layer 3 — Property/fuzz tier

Deferred. Document as a future option once Layers 1 + 2 are stable.

---

## Layer 1 — Fixture suite

### Directory layout

```
Tests/CmuxAgentXrayTests/
├── E2E/
│   ├── E2EFixture.swift                       # shared loader
│   └── Claude/
│       ├── RewindFoldsTailE2E.swift
│       ├── ParallelToolCallE2E.swift
│       ├── PoolMultiChildE2E.swift
│       ├── HookSuccessOrphanParentE2E.swift
│       ├── QueuedPromptViaAttachmentE2E.swift
│       ├── QueuedSlashCmdConsumeE2E.swift
│       ├── TaskNotificationFilteredE2E.swift
│       ├── MultiBlockAssistantE2E.swift
│       ├── MinimalConversationE2E.swift
│       └── SingleToolTurnE2E.swift
└── Fixtures/
    └── Claude/
        ├── rewind-folds-tail/
        │   ├── input.jsonl
        │   ├── README.md
        │   └── regenerate.json
        ├── parallel-tool-call/...
        └── ...
```

`E2E/` (test code) and `Fixtures/` (data) are parallel trees so
SPM's `resources: [.copy("Fixtures")]` doesn't conflict with source
compilation. Each scenario directory carries:

- `input.jsonl` — the trimmed-and-redacted JSONL fixture
- `README.md` — one paragraph: what shape this pins, why it matters
- `regenerate.json` — the predicate the fixture-regenerator uses to
  pick a matching corpus session

### Initial scenario list (10 fixtures)

| Scenario | Lines | Pins |
|---|---:|---|
| `minimal-conversation` | ~6 | A1 baseline shape |
| `single-tool-turn` | ~8 | tool_use → tool_result happy path |
| `rewind-folds-tail` | ~12 | rewind detector + `Transcript.branchOff` |
| `parallel-tool-call` | ~10 | `awaitingParent` pool drain |
| `pool-multi-child` | ~12 | the 2+-children-on-same-parent case that crashed dogfood |
| `hook-success-orphan-parent` | ~6 | empty-path alias fallback for skipped lines with null parentUuid |
| `queued-prompt-via-attachment` | ~10 | FIFO consume via `attachment.queued_command` |
| `queued-slash-cmd-consume` | ~8 | FIFO consume via slash-cmd line (the case that disproved the brief's "only attachment consumes" claim) |
| `task-notification-filtered` | ~5 | enqueue filter at intake — `<task-notification>` payloads must NOT push onto FIFO |
| `multi-block-assistant` | ~4 | multi-block-per-line id-suffix tie-breaker |

Total committed JSONL: ~80 lines across 10 fixtures.

### Test pattern

Each scenario's Swift file is a `@Suite` with one or more `@Test`
methods asserting on the loaded `[Entry]` shape:

```swift
@Suite("E2E — rewind-folds-tail")
struct RewindFoldsTailE2E {
    @Test func transcriptShape() throws {
        let entries = try E2EFixture.loadAndBuild("rewind-folds-tail")
        // top-level: [user, branchLink-with-abandoned-agent, user]
        try #require(entries.count == 3)
        guard case .synthesized(let link) = entries[1],
              case .branchLink = link.kind else {
            Issue.record("expected branchLink at slot 1; got \(entries[1])")
            return
        }
        #expect(link.subEntries.count == 1)
        if case .agent(let abandoned) = link.subEntries[0] {
            #expect(abandoned.id == .fromJSONL("a1"))
        } else {
            Issue.record("expected abandoned .agent inside branchLink")
        }
    }
}
```

### Shared loader (`E2EFixture.swift`)

```swift
internal enum E2EFixture {
    /// Load fixture JSONL from `Fixtures/Claude/<name>/input.jsonl`.
    static func loadInput(_ scenario: String) throws -> [ClaudeJSONLLine] {
        let url = try fixtureURL(scenario: scenario, name: "input.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n")
            .filter { !$0.isEmpty }
            .map { try AgentXrayJSON.decoder.decode(ClaudeJSONLLine.self, from: Data($0)) }
    }

    /// Run the fixture through `ClaudeTranscriptBuilder` and return the
    /// resulting top-level entries.
    static func loadAndBuild(_ scenario: String) throws -> [Entry] {
        let lines = try loadInput(scenario)
        var builder = ClaudeTranscriptBuilder()
        for line in lines { builder.ingest(line) }
        return builder.transcript()
    }

    /// As above, with a CapturingLogger so assertions can introspect
    /// warnings (e.g., "tool_result for tool_use_id X with no matching
    /// ToolEntry" — the orphan-tool-result drop path).
    static func loadAndBuildWithLogger(_ scenario: String)
        throws -> (entries: [Entry], logs: [(level: String, body: String)])
    { ... }

    private static func fixtureURL(scenario: String, name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/Claude/\(scenario)"
        ) else {
            throw E2EFixtureError.notFound(scenario: scenario, name: name)
        }
        return url
    }
}
```

### Package.swift addition

```swift
.testTarget(
    name: "CmuxAgentXrayTests",
    dependencies: ["CmuxAgentXray"],
    resources: [.copy("Fixtures")]
)
```

Resource directory copied verbatim into the test bundle. `Bundle.module`
resolves the `Fixtures/Claude/<scenario>/input.jsonl` path at runtime.

### Migration of existing tests

Seven of the current `ClaudeTranscriptBuilderTests` tests are scenario-
shaped and migrate cleanly to fixtures. Three are fine-grained unit
tests and stay inline.

| Existing test | Action |
|---|---|
| `interleavedAssistantTextAndTools` | Keep inline (sub-entry arrival-order unit) |
| `multipleThinkingBlocksDoNotCoalesce` | Keep inline |
| `interleavedThinkingTextTools` | Keep inline |
| `toolResultBeforeToolUseIdempotentSlot` | Migrate → `Fixtures/Claude/orphan-tool-result/` |
| `outOfOrderToolResultPoolDrain` | Migrate → `Fixtures/Claude/parallel-tool-call/` |
| `rewindFoldsAbandonedTail` | Migrate → `Fixtures/Claude/rewind-folds-tail/` |
| `queuedSlashCmdConsumesFIFO` | Migrate → `Fixtures/Claude/queued-slash-cmd-consume/` |
| `unconsumedEnqueueRemainsPending` | Migrate → `Fixtures/Claude/unconsumed-enqueue/` |
| `turnDurationStampsAgentEntry` | Migrate → `Fixtures/Claude/turn-duration-stamp/` |
| `skippedOrphanAttachmentDoesNotBlockDescendants` | Migrate → `Fixtures/Claude/hook-success-orphan-parent/` |

After migration, total scenario fixtures = 10. The four kept-inline
tests stay in `ClaudeTranscriptBuilderTests.swift`.

---

## Layer 2 — Corpus invariant suite

### Trigger

Auto-runs **only when `~/.claude/projects/` exists**. No env flag.
On a fresh-clone developer machine or CI without that directory, the
suite skips cleanly.

```swift
@Suite("E2E — corpus invariants")
struct CorpusInvariantsE2E {
    @Test("Every selected session builds without crash + structural invariants hold")
    func corpusInvariants() throws {
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        guard FileManager.default.fileExists(atPath: claudeProjects.path) else {
            return  // skip — no local corpus
        }
        let sessions = try selectHeterogeneitySessions(corpusRoot: claudeProjects)
        for session in sessions {
            try assertInvariants(session: session)
        }
    }
}
```

### Selection algorithm

Two-stage greedy per project — picks 10 sessions that span the
feature space, then falls back to recency.

```swift
func selectHeterogeneitySessions(corpusRoot: URL) throws -> [URL] {
    let projects = mostRecentProjects(corpusRoot, limit: 3)  // by mtime
    var picked: [URL] = []
    for project in projects {
        picked += selectFromProject(project, limit: 10)
    }
    return picked
}

func selectFromProject(_ project: URL, limit: Int) -> [URL] {
    let sessions = jsonlFiles(project, sortedByMTimeDesc: true)
    let fingerprints = sessions.map { ($0, fingerprint($0)) }
    var picked: [URL] = []
    var covered: Set<Feature> = []
    // Stage 1 — newest-first, only pick if it adds a new feature flag
    for (url, fp) in fingerprints {
        let newFlags = fp.subtracting(covered)
        if !newFlags.isEmpty {
            picked.append(url)
            covered.formUnion(newFlags)
        }
        if picked.count == limit { return picked }
    }
    // Stage 2 — fill remainder from most-recent unpicked
    for (url, _) in fingerprints {
        if picked.count == limit { break }
        if !picked.contains(url) { picked.append(url) }
    }
    return picked
}

enum Feature: Hashable {
    case rewind, subAgent, queuedPrompt, parallelToolCall,
         compactBoundary, apiError, multiBlockAssistant,
         hookSuccessOrphan, slashCmdConsume
}

func fingerprint(_ session: URL) -> Set<Feature> { /* scan + flag */ }
```

Coverage saturates fast (typically 4-7 picks); the rest fall back to
recency. Worst case: 30 sessions per CI run (3 × 10).

### Invariants per session (structural only)

| Invariant | Assertion |
|---|---|
| No crash | The build returning at all = pass |
| No silent line drop | Every input uuid is in `transcript.index` OR `awaitingParent` (DEBUG seam exposed via builder) |
| Transcript size sanity | `entries.count > 0` for non-empty input |
| Top-level invariants | No `.text` / `.tool` at top level |
| Sub-entry parent integrity | Every `.text` / `.tool` is inside an `.agent` or `.synthesized` |
| AgentEntry pairing | Every `.agent` has at least 1 sub-entry OR a non-zero `usage` |
| Pool empty post-build | `awaitingParent.count == 0` after end-of-stream — anything left signals a session-data orphan |

**Crucially: no exact-string assertions.** No assertion on user prompt
text, assistant text, tool result content, file paths, etc. Format-
drift-resistant.

### Builder seam

Add a DEBUG-only public accessor on `ClaudeTranscriptBuilder` (or a
test-internal hook via `@testable import`) that exposes:

- `awaitingParentCount() -> Int` — for the post-build check
- `indexedUuidsCount() -> Int` — for total-coverage check
- `inputLineCount() -> Int` — for the silent-drop ratio check

These ship behind `#if DEBUG` so production builds don't carry them.

### Failure logging

On invariant failure, log: session path, `entries.count`, line count,
the specific invariant that failed, first 5 lines of the input.
Don't log session contents wholesale (PII) — only structural
metadata.

---

## Fixture regenerator (Swift CLI)

`Packages/CmuxAgentXray/Tools/RegenerateE2EFixtures/` — separate Swift
executable target.

```swift
// Package.swift
.executableTarget(
    name: "RegenerateE2EFixtures",
    dependencies: ["CmuxAgentXray"],
    path: "Tools/RegenerateE2EFixtures"
)
```

Run via `swift run RegenerateE2EFixtures`. No flags, no prompts.

### Per-fixture predicate

Each `Fixtures/Claude/<scenario>/regenerate.json`:

```json
{
  "predicate": {
    "hasRewind": true,
    "hasSubAgent": false,
    "hasParallelToolCall": false
  },
  "minLines": 5,
  "maxLines": 50,
  "preserveUuids": false
}
```

Tool walks `~/.claude/projects/`, scores each session against each
fixture's predicate, picks the smallest matching session, trims to a
self-contained sub-chain of `[minLines ... maxLines]`, redacts,
writes `input.jsonl`. If no session matches, prints a warning and
leaves the existing fixture untouched.

### Redaction policy

**Preserves (structural — drives routing):**
- All `uuid`, `parentUuid`, `timestamp`, `sessionId` fields (regenerated to anonymous values; structural relationships preserved)
- All `type`, `subtype`, `operation` fields
- `attachment.type`, `attachment.commandMode`
- `message.content` array structure (block.type entries preserved)
- `tool_use.name`, `tool_use.id`, `tool_result.tool_use_id`, `tool_result.is_error`
- `<command-name>cmd</command-name>` markers — drive slash-cmd routing
- `<task-notification>`, `<local-command-stdout>`, `<local-command-stderr>`, `<system-reminder>`, `<command-message>` tag wrappers
- `model`, `stopReason`, `usage`, `durationMs`, `messageCount`
- `isSidechain`, `parentToolUseID`
- `logicalParentUuid` (for compact_boundary stitching)

**Redacts:**
- `message.content[*].text` (assistant + user) → `"<redacted text N words>"` where N preserves the word count
- `message.content[*].thinking` → `"<redacted thinking N words>"`
- `tool_use.input` → recursively replace string leaves with `"<redacted>"`, keep key shape + types
- `tool_result.content[*].text` → `"<redacted result>"` (preserves `is_error` + shape)
- `attachment.prompt.text` (queued prompt content) → `"<redacted prompt>"`
- File paths anywhere (`file_path`, `cwd`, `path`, etc.) → `"/redacted/path"`
- Email addresses, URLs (with hostnames), ticket-ID-shaped strings → masked

**Tests can assert on:** entry kinds, status enums, sub-entry counts,
routing decisions (`branchLink` exists, FIFO consumption fires),
token-usage aggregation, durationMs presence.

**Tests cannot assert on:** specific prompt text, specific assistant
text, file paths, customer-data-bearing strings.

### Audit gate for the redactor

Adding the redactor doesn't guarantee redaction is complete. **Next
session, after the redactor lands, run a separate audit:** scan the
generated fixtures for residual PII. Specifically:

1. Grep generated `input.jsonl` files for the user's home directory
   path, common email-shaped substrings, ticket-ID patterns, common
   secrets-adjacent strings.
2. For each `redacted` placeholder, count word vs. content
   distribution to confirm preservation rules held.
3. Cross-check against a hand-crafted "known PII" sentinel session
   (containing canary strings) — the redactor should mask all
   canaries.

If the audit finds gaps, extend the redactor's preserve/redact
policy and regenerate.

---

## Acceptance criteria

### Layer 1
- 10 fixtures committed under `Tests/CmuxAgentXrayTests/Fixtures/Claude/`.
- 10 e2e Swift suites under `Tests/CmuxAgentXrayTests/E2E/Claude/`.
- `E2EFixture.swift` shared loader landed.
- 7 existing tests migrated; 3 kept inline.
- `swift test` runs in <100ms total.

### Layer 2
- `CorpusInvariantsE2E.swift` compiled, auto-runs when `~/.claude/projects/` exists, skips cleanly otherwise.
- Builder DEBUG seam exposing `awaitingParentCount` / `indexedUuidsCount` / `inputLineCount`.
- Heterogeneity selection fingerprint script runs in <500ms across 30 sessions.

### Fixture regenerator
- `swift run RegenerateE2EFixtures` runs with no flags.
- Each fixture has a `regenerate.json` declaring its predicate.
- PII-audit pass logged in next session's commit message.

### Tests pass at 162/20 → ~172/22 (10 new e2e suites + corpus suite + redactor sanity = ~10 added test methods).

---

## Implementation order

Recommended execution sequence for the next session:

1. **`E2EFixture.swift` loader + `Package.swift` resources hook** (one commit). Verify a single hand-authored `Fixtures/Claude/sanity-check/input.jsonl` loads + builds.
2. **Migrate one existing test to fixtures** (e.g., `rewindFoldsAbandonedTail` → `Fixtures/Claude/rewind-folds-tail/`). Verify the migrated assertion still passes.
3. **Migrate the remaining 6 scenario-shaped tests + author the 3 net-new fixtures** (one commit per migration is fine; all 10 in one commit is also fine).
4. **Builder DEBUG seam** for invariant-checking (`awaitingParentCount` etc.). One commit.
5. **`CorpusInvariantsE2E.swift` + heterogeneity selection** (one commit). Verify on local corpus.
6. **`RegenerateE2EFixtures` CLI executable + per-fixture `regenerate.json` files** (one commit). Verify it overwrites a fixture cleanly without losing the existing scenario-pinning predicate.
7. **PII audit pass** (separate commit) — confirm redactor coverage; document findings.
8. **Update `MIGRATION_PLAN.md` §16 + this handover doc** retiring marker (one commit).

---

## Standing rules

- **No exact-string assertions** on user prompts / assistant text /
  tool result body text in any e2e test. Structural shapes only.
- **Don't commit non-redacted real-corpus JSONL.** All fixtures pass
  through the redactor or are hand-authored.
- **Layer 2 must be auto-skip-on-missing-corpus.** Fresh-clone CI
  must not fail.
- **Selection algorithm runs deterministically** for any given
  corpus state — given the same corpus mtime ordering, picks the
  same sessions every run.
- **Fixture-regeneration is opt-in.** Running `RegenerateE2EFixtures`
  is never required — fixtures only refresh when the user explicitly
  decides to.

---

## Open items not yet decided

- Should the Layer 2 suite run in CI (fresh checkout, no corpus) or
  only on developer machines? Today's answer: **only when corpus
  exists**, which de-facto means developer machines. Decide if CI
  should mount a sample-corpus fixture for it; not today's problem.
- Should redactor support a `--dry-run` mode? Probably yes,
  trivial to add.
- Should fixtures carry a `last-regenerated` timestamp in their
  `regenerate.json`? Nice-to-have for staleness tracking.
