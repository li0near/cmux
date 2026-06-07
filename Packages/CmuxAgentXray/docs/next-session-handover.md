# AgentX-ray — pending work handover (2026-06-08, post-Phase-F)

This doc replaces the prior 2026-06-08 post-Phase-E handover. Phase F
(commits `a73d3a84b` … `4458cd082`, MIGRATION_PLAN.md §14 row 19u)
finished the content-type cleanup that Phase E's plumbing layered on
top of Phase D-rev's wrong-shape carriers — see the row for the full
diff. Highlights of the resulting end state:

- Edit / MultiEdit input renders inline as colored diff hunks
  (`Section.text(_, .diffAdded/.diffRemoved)` from
  `ToolInputParser.diffSections`) with light-green / light-red
  tinted backgrounds; adjacent removed/added pairs paint as one
  contiguous flat-edge block.
- `DetailContent` carries one `source: DetailSource` discriminated
  payload (file / text / image / transcript). The cmux host's
  `openDetailTab` switches on the source variant directly — no
  per-tool ContentType inference, no parallel `openImageInPanel`
  method, no body-bytes carrier the host might re-read.
- The materialize helpers dedup at two levels: existing on-disk
  file short-circuits cold re-clicks; an in-memory
  `[String: Task<URL?, Never>]` map on `AgentXrayWorkspaceHost`
  short-circuits warm re-clicks against the same temp path during
  the write window (concurrent-write race fix).
- The shape sniffer's diff arm (≥2-of-3 patterns) now catches
  `git diff` Bash output so the detail tab opens it as `.diff`.

## Verify baseline before starting

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline                              # → 4458cd082 (or later)
swift test --package-path Packages/CmuxAgentXray  # → 143 tests / 19 suites green
```

For UI verification:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agentxray --launch
```

Click `↗ Open detail` on each row content shape and confirm the
right cmux panel opens:
- markdown / code / json / plain text → cmux `MarkdownPanel` or
  `FilePreviewPanel` (extension-driven dispatch via the
  resolver's `suggestedFilename`).
- Edit / MultiEdit input rows → row body shows green/red diff
  blocks with light-tinted backgrounds; click opens the
  synthesized unified diff as `tool-input.diff`.
- diff Bash output → opens as `tool-result.diff` with
  highlight.js diff coloring.
- image (user paste or Playwright screenshot) → `FilePreviewPanel`
  with native zoom / pan / rotate; user image-only messages also
  resolve correctly (Phase F arm).
- offloaded outputs → cmux opens the on-disk file directly (no
  re-materialization).
- sub-agent / abandoned-branch transcript → AgentX-ray detail mode
  (in-package rendering, unchanged).

---

## Pending work queue (small)

### D-rev FU 3 — Richer transcript renderer

Sub-agent and abandoned-branch transcripts still render in-package
via `TranscriptView.detailEntriesList` + the `EntryView` dispatcher.
Functional and intentional — those are structured Entry arrays, not
file-shaped. A future phase may add navigation chrome (sticky turn
header, per-turn stats, search-in-transcript, fold-to-headers,
diff-vs-parent for abandoned branches). Scope decisions deferred
until the user is ready to design that phase.

### Screenshot vs Image discrimination (small)

Inline label is universally "Image" today. Discriminating
"Screenshot" specifically (for tool-result images from
`browser_take_screenshot`-shaped tools) would need the tool name
threaded into `ToolResultParser`. Phase F already routes such
images to a `screenshot.<ext>` filename so cmux's panel pipeline
opens them with the right title; the inline label change is the
remaining piece. Small follow-up if it becomes user-visible.

### Pane placement fine-tuning

Phase E uses cmux's default placement (focused pane, no focus
steal — `activate: false` on `openFileInPanel`). If users want a
specific behavior — sibling-pane open, dedicated detail
workspace, etc. — a one-line change in
`AgentXrayWorkspaceHost.openFileInPanel` (or the
`openDetailTabRouting` call sites) tunes the parameters.

### Audit deferred items

- **S3** — system / compact entries silently drop images. Builder
  side; corpus has 0 hits today, deferred. Files:
  `ClaudeTranscriptBuilder.buildSystemEntry` and `buildCompactEntry`.

### `AgentXrayPanel.detail` mode survives but is shrunk

Used only for transcript content now. A future phase may decide
whether the detail mode itself is still warranted given that
transcripts could become a separate cmux panel kind. Out of scope
for now.

---

## Cross-doc map (current)

| Doc | Role |
|---|---|
| `README.md` | Package overview, vocabulary, layer map, host integration. |
| `MIGRATION_PLAN.md` | Per-phase commit ledger (§14 rows 19a–19u), bug-fix ledger (§15), deferred-by-policy items (§16), origin cross-reference (§18). |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (§11 has the canonical block-type table). |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH, RemoteSessionStore). |
| `docs/next-session-handover.md` | **(this doc)** Pending work queue — transcript renderer, screenshot discrimination, pane placement, S3. |

If any doc disagrees with the code, the code wins — fix the doc in
the same change.
