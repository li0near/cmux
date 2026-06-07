# AgentX-ray — pending work handover (2026-06-08, post-Phase-D-rev)

This doc replaces the prior 2026-06-07 handover (which queued four
hand-rolled rich renderers — JSON / Diff / Markdown / Code — as Phase
D follow-ups). That queue is **fully retired**: Phase D-rev landed the
detail-tab rich rendering by delegating to cmux-native surfaces
(commits `4006c9a1f` … `bb4a9c524`, MIGRATION_PLAN.md §14 row 19s).
At HEAD `bb4a9c524`, clicking a detail tab renders markdown / code /
diff / json / plain text via cmux's bundled `MarkdownWebRenderer`
(marked.js + highlight.js) and inline-base64 images via Apple's
`QLPreviewView` (`QuickLookUI`) with native zoom + pan + spacebar
QuickLook.

Active queue below is short — only the audit-deferred items that
weren't part of Phase D-rev.

## Verify baseline before starting

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline                              # → bb4a9c524 (or later)
swift test --package-path Packages/CmuxAgentXray  # → 114 tests / 18 suites green
```

For UI verification:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agentxray --launch
```

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

### M2 — `DetailContentOffloadedOutputTests` resolver-arm test

The Phase C resolver's file-read arm (`resolveOffloadedOutput`) is
covered indirectly via integration but has no dedicated test file.
Fast to add: temp-file fixture for the success path, deleted-file
fixture for the error fallback path.

Files: new `Tests/CmuxAgentXrayTests/Panel/DetailContentOffloadedOutputTests.swift`.

Cost: trivial. Should land alongside HI #2's async-resolver migration.

---

## Phase D-rev follow-ups (small, optional)

The detail-tab delegation strategy left two minor hooks that the
next session may want to wire when they become user-visible:

### Language detection from `file_path` extension

Read / Edit.new_string / Write.content tool-result text is currently
classified `.plainText` despite the surrounding tool input carrying a
known `file_path`. After detection, those would land as
`.code(language: ext)` and the host's MarkdownWebRenderer wrapper
fences them with the right highlight.js language hint instead of the
no-language fallback. Verified worthwhile in the corpus survey: ~36%
of tool-results would gain syntax highlighting (525 Read + 342
Edit.new_string + 36 Write.content out of 2353 results sampled).

Edits go in `Panel/DetailContentShapeSniffer.swift` — extend the
classifier to take an optional `tool: ToolEntry?` so it can read
sibling input. New tests for the extension → language mapping.

### `FileExternalOpenMenu` accessory wiring

The host protocol seam `detailExternalOpenAccessory(for:)` returns
`nil` today. Wires up alongside the language-detection PR — when a
detail tab is backed by a real on-disk path (e.g. Read of
`/foo/bar.swift`), the host returns `FileExternalOpenMenu(fileURL:)`
which gives users "Open in Xcode / VS Code / Preview / …" identical
to cmux's terminal-URL-click flow.

### Transcript renderer (next big phase, deferred from Phase D-rev)

`.transcript` content (sub-agent transcripts, abandoned-branch
links) still renders in-package via `TranscriptView.detailEntriesList`
and the `EntryView` dispatcher — same code that powers the live
panel. That's intentional: per the Phase D-rev scope, the transcript
case is the only `ContentType` that stays in-package for now.
Future phase can promote this to a richer surface if desired
(e.g. timeline view, collapsible turns) but the current shape is
production-ready.

---

## Cross-doc map (current)

| Doc | Role |
|---|---|
| `README.md` | Package overview, vocabulary, layer map, host integration. |
| `MIGRATION_PLAN.md` | Per-phase commit ledger (§14 rows 19a–19s), bug-fix ledger (§15), deferred-by-policy items (§16), origin cross-reference (§18). |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (§11 has the canonical block-type table). |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH, RemoteSessionStore). |
| `docs/next-session-handover.md` | **(this doc)** Pending work queue — audit deferrals + Phase D-rev follow-ups. |

If any doc disagrees with the code, the code wins — fix the doc in
the same change.
