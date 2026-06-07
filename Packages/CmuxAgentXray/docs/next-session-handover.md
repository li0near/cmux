# AgentX-ray — pending work handover (2026-06-07, post-cleanup)

This doc replaces the previous handover (which was retired after Phases
A–E landed) with the queue of work that's **still pending** after the
2026-06-07 audit-cleanup pass.

The two big buckets are:
1. **Phase D follow-up rich renderers** — four detail-tab format
   renderers, foundation already in place. One per format.
2. **Audit deferred items** — known limitations and unfinished
   audit-flagged work that didn't make the cleanup commits.

`MIGRATION_PLAN.md` §16 still tracks the deferred-by-policy items
(B/C/E/G/K/L/N/O); this doc is the active queue.

## Verify baseline before starting

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline                              # → 55bcc87bb (or later)
swift test --package-path Packages/CmuxAgentXray  # → 110 tests / 17 suites green
```

For UI verification:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agentxray --launch
```

---

## Phase D follow-up: rich detail-tab renderers

Phase D landed the foundation: `ContentType` enum extended with
`.markdown / .code(language:) / .json / .diff`; `TextStyle` extended
with `.diffAdded / .diffRemoved / .codeMonospace`; four stub views in
`Views/Sections/` that satisfy the dispatch wiring with one-line
`Text(...)` placeholders. Phase E hooked them into the detail-tab
dispatch via `DetailContentShapeSniffer`.

Each renderer is independently reviewable — no cross-dependencies
beyond the foundation.

### 1. JSON renderer (recommended first — smallest)

Current state: `JsonSectionView` pretty-prints via
`JSONSerialization.data(withJSONObject:options:.prettyPrinted)` and
renders the result in a monospace `Text(...)`.

Goal: syntax coloring via `AttributedString` runs over the
pretty-printed text:
- Object/array braces + commas → `palette.dim`
- Keys (quoted strings before `:`) → `palette.cyan`
- String values → `palette.green`
- Number / bool / null → `palette.magenta`
- Optional: collapsible `{...}` / `[...]` nodes (post-1.0).

Files: `Views/Sections/JsonSectionView.swift`. May add a small
`JsonTokenizer` helper struct (could live in `Adapters/Common/` if
agent-agnostic, or `Views/Helpers/`).

Cost: small — a few hours.

### 2. Diff renderer (recommended second)

Current state: `DiffSectionView` splits on `\n` and applies per-line
`+`/`-` prefix coloring (green/red) to a monospace text view.

Goal: patch-aware rendering:
- Parse `@@ -<old>,<oldlen> +<new>,<newlen> @@` hunk headers.
- Group context lines + add/remove lines per hunk.
- Render each hunk with a header strip + content rows.
- Optional: in-line word-level highlights for changed regions
  (post-1.0).

Files: `Views/Sections/DiffSectionView.swift`. Probably a small
`DiffParser` or `UnifiedDiffParser` helper in `Views/Helpers/`.

Cost: small-medium.

### 3. Markdown renderer

Current state: `MarkdownSectionView` renders as plain
`Text(...).font(Theme.DetailPanel.body)`.

Goal: heading + bullet + fenced-code-block + link rendering. Apple's
`AttributedString(markdown:)` does most of the work:
- Headings (`### Foo`) → bold + larger size.
- Bullets (`-`, `*`) → indent + bullet glyph.
- Fenced code (` ```js ... ``` `) → handed off to `CodeSectionView`
  (recursive composition). Or render inline as monospace.
- Inline code (` `foo` `) → monospace runs.
- Links → tappable.

Phase E's `DetailContentShapeSniffer.splitMarkdownSections(text:)`
already extracts heading-bounded segments — the renderer can either
flatten them back or render with a heading sidebar / TOC.

Files: `Views/Sections/MarkdownSectionView.swift`. Possibly a
`MarkdownRenderer` helper if `AttributedString(markdown:)` proves
insufficient.

Cost: medium. Apple API does the heavy lifting; the integration is
mostly wiring + theme tuning.

### 4. Code renderer (most expensive — leave for last)

Current state: `CodeSectionView` renders monospaced `Text(...)` with
an optional language label.

Goal: per-language syntax highlighting for the languages in the
corpus today (`js`, `swift`, `python`, `bash`, `sh`, `tsx`, `ts`).

Two approaches:

**A. Pull in a small dependency.** [`Splash`](https://github.com/JohnSundell/Splash)
is the canonical SwiftPM-friendly choice but is Swift-language only.
[`Highlightr`](https://github.com/raspu/Highlightr) wraps highlight.js
via `WKWebView` — heavier but covers everything. Either adds an SPM
dependency to the package.

**B. Hand-rolled tokenizer.** Implement a minimal regex-based
tokenizer for the four most-common languages observed in tool-result
content. Saves the dependency at the cost of maintenance.

Cost: medium-large. Recommend A with `Splash` for Swift-first scope;
expand if other languages need coverage.

### Suggested execution order

1. JSON (small, builds on existing pretty-print).
2. Diff (small-medium, builds on existing per-line coloring).
3. Markdown (medium, Apple API does most of the work).
4. Code (medium-large, may pull in dependency).

Each ships as its own PR. After all four, `MIGRATION_PLAN.md` §16
gains nothing — the renderers fully realize the Phase D foundation.

---

## Audit deferred items

These came out of the post-Phase-A–E independent audit pass and
weren't trimmable in the cleanup commits.

### HI #2 — Async resolver for `resolveOffloadedOutput`

**File**: `Panel/DetailContent.swift:resolveOffloadedOutput(_:tool:timestamp:)`.

The Phase C file-read uses synchronous `String(contentsOf:encoding:)`
on the `@MainActor`. Corpus contains files up to ~1.2 MB — bounded
but perceptibly janky on slow disks or very large outputs.

Migrating requires making `DetailContent.resolve(...)` async and
cascading through every caller (`AgentXrayPanel.openDetail`,
`TranscriptView.detailView`). A wider resolver-pipeline async
refactor.

Tracked in `MIGRATION_PLAN.md` §16.O. Not blocking — file reads stay
under main-thread budget for the corpus's median size.

### S3 — System / compact entries silently drop images

**Files**: `ClaudeTranscriptBuilder.swift`'s `buildSystemEntry` and
`buildCompactEntry`.

After commit 3 of the cleanup pass, these use `allText()` from the
Wire layer for text projection. Image blocks aren't projected (system
and compact paths return a `String`, not `[Section]`).

Corpus has 0 hits today for system/compact entries with images, so
silent drop is fine. If a future corpus shows them, lift these two
builders to `[Section]` emission via a sibling parser
(structurally similar to `UserContentParser`).

### S4 — `.codeMonospace` `TextStyle` doesn't switch font in inline renderers

**Files**: `Views/AgentEntryView+CappedBody.swift`,
`Views/EntryBodyView.swift`.

Phase D's `TextStyle` extension added `.codeMonospace`, but neither
inline renderer switches the font for that case (both use
`Theme.SubRow.title` regardless). Foundation-only until a producer
sets the style. The producer would be a future Code renderer or the
markdown's inline-code mapping.

Trivial fix: add a `font(for: TextStyle) -> Font` helper analogous to
the existing `color(for: TextStyle)` lifted to `HudPalette`. Land it
when the first `.codeMonospace` producer ships.

### M2 — `DetailContentOffloadedOutputTests` resolver-arm test

The Phase C resolver's file-read arm (`resolveOffloadedOutput`) is
covered indirectly via integration but has no dedicated test file.
Fast to add: temp-file fixture for the success path, deleted-file
fixture for the error fallback path.

Files: new `Tests/CmuxAgentXrayTests/Panel/DetailContentOffloadedOutputTests.swift`.

Cost: trivial. Should land alongside HI #2's async-resolver migration.

---

## Cross-doc map (current)

| Doc | Role |
|---|---|
| `README.md` | Package overview, vocabulary, layer map, host integration. |
| `MIGRATION_PLAN.md` | Per-phase commit ledger (§14 rows 19a–19r), bug-fix ledger (§15), deferred-by-policy items (§16), origin cross-reference (§18). |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (§11 has the canonical block-type table). |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH, RemoteSessionStore). |
| `docs/next-session-handover.md` | **(this doc)** Pending work queue — Phase D renderers + audit deferrals. |

If any doc disagrees with the code, the code wins — fix the doc in
the same change.
