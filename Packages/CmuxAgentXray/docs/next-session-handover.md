# AgentX-ray — pending work handover (2026-06-08, post-Phase-E)

This doc replaces the prior 2026-06-08 handover (which queued
HI #2 + M2 + FU 1 + FU 2 as small deferrals on top of Phase D-rev).
**That entire queue is retired** — Phase E (commits `b2a14e895` …
`87a5ac1d1`, MIGRATION_PLAN.md §14 row 19t) made all four moot by
redirecting detail-tab opens through cmux's existing
`Workspace.openFileSurfaces` panel pipeline. Users now get full
cmux panel chrome (font / copy / edit / "Open in…" / image zoom)
on every detail tab for free.

## Verify baseline before starting

```bash
cd /Users/<user>/temp/github/cmux-agentxray
git log -1 --oneline                              # → 87a5ac1d1 (or later)
swift test --package-path Packages/CmuxAgentXray  # → 110 tests / 17 suites green
```

For UI verification:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
./scripts/reload.sh --tag agentxray --launch
```

Click `↗ Open detail` on each row content shape and confirm the
right cmux panel opens:
- markdown / code / diff / json / plain text → cmux
  `MarkdownPanel` or `FilePreviewPanel` (extension-driven dispatch)
- image (user paste or Playwright screenshot) → `FilePreviewPanel`
  with native zoom / pan / rotate
- offloaded outputs → cmux opens the on-disk file directly
- sub-agent / abandoned-branch transcript → AgentX-ray detail mode
  (in-package rendering, unchanged)

---

## Pending work queue (small)

### D-rev FU 3 — Richer transcript renderer

The only `.transcript`-shaped detail content (sub-agent + abandoned
branches) still renders in-package via `TranscriptView.detailEntriesList`
+ the `EntryView` dispatcher. Functional and intentional — those
are structured Entry arrays, not file-shaped. A future phase may
add navigation chrome (sticky turn header, per-turn stats,
search-in-transcript, fold-to-headers, diff-vs-parent for
abandoned branches). Scope decisions deferred until the user is
ready to design that phase.

### Screenshot vs Image discrimination (small)

Inline label is universally "Image" today. Discriminating
"Screenshot" specifically (for tool-result images from
`browser_take_screenshot`-shaped tools) needs the tool name
threaded into `ToolResultParser`. Small follow-up if it becomes
user-visible. Not blocking.

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
| `MIGRATION_PLAN.md` | Per-phase commit ledger (§14 rows 19a–19t), bug-fix ledger (§15), deferred-by-policy items (§16), origin cross-reference (§18). |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (§11 has the canonical block-type table). |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH, RemoteSessionStore). |
| `docs/next-session-handover.md` | **(this doc)** Pending work queue — transcript renderer, screenshot discrimination, pane placement, S3. |

If any doc disagrees with the code, the code wins — fix the doc in
the same change.
