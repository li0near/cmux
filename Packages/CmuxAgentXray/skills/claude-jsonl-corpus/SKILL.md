---
name: claude-jsonl-corpus
description: Maintain the empirical corpus survey of Claude Code's session JSONL format. Use when working on AgentX-ray adapter / Claude JSONL parsing, encountering a new line type / subtype / wire-shape / edge case the docs don't cover, hitting an inconsistency between the docs and observed behavior, debugging a dispatcher mis-route on an unfamiliar shape, validating an empirical claim before acting on it, or after a Claude Code release that may have shifted wire formats. Also use when scanning `~/.claude/projects/*.jsonl` for any corpus question — line counts, type distributions, parentUuid chain shapes, rewind patterns, queued-prompt flow, sub-agent sidechain, etc.
---

# Claude Code JSONL — corpus survey & docs maintenance

Two paired docs capture what we know about Claude Code's session
JSONL wire format and how our adapter consumes it:

- `Packages/CmuxAgentXray/docs/corpus-survey.md` — **empirical
  wire-format truth.** What's actually in the JSONL files in
  `~/.claude/projects/`. Categories, patterns, syntax, deviations,
  audit numbers. Living doc maintained across sessions.
- `Packages/CmuxAgentXray/docs/claude-jsonl-mapping.md` — **how
  OUR code consumes that truth.** Dispatcher routing tables, model
  shape, per-line dispatch flow, content-block reference. Maintenance
  reference for the dispatcher, parsers, and resolvers.

Both are checked into the repo. Both can become stale silently when
Claude Code rolls out wire-format changes between releases. **Treat
them as a paired surface.** Updates to the corpus survey often
require parallel updates to the mapping doc, and vice versa.

## When to invoke this skill

- Working on `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/**`
  and you encounter a JSONL shape that doesn't match the docs.
- A user reports a transcript rendering bug that traces back to an
  unfamiliar wire shape.
- After a Claude Code release where you suspect format drift.
- Before relying on an empirical claim from the docs in code that
  ships (the methodology has been wrong before — see "Empirical
  invariants can be wrong" below).
- Adding support for a new content-block type, line type, or
  attachment subtype.
- A Plan agent or audit asks to verify a corpus invariant.

## Workflow

### 1. Read both docs first

Always read both `corpus-survey.md` and `claude-jsonl-mapping.md`
end-to-end before scanning the corpus. The first might already
cover what you're looking at; the second tells you how the
dispatcher currently routes the shape.

### 2. Scan the corpus

Corpus location:
```
~/.claude/projects/<dir-encoded-cwd>/<sessionId>.jsonl
```

NDJSON — one JSON object per line. Use Python (or shell + `jq`)
for ad-hoc scans. Typical scan shape:

```python
import json, glob
counts = {}
for path in glob.glob('~/.claude/projects/**/*.jsonl', recursive=True):
    try:
        with open(path) as fh:
            for line in fh:
                d = json.loads(line)
                # ... your investigation ...
    except Exception:
        continue
```

Common scan questions worth re-running:

- Distribution of `type` values (and `subtype` for `system` /
  `attachment`).
- Distribution of `attachment.type` and `attachment.commandMode`.
- Lines per type per session (helps identify rare-but-real shapes).
- parentUuid chain integrity (does every parentUuid resolve to a
  prior line's uuid?).
- Out-of-order parents (lines whose parentUuid resolves to a
  later line in file order).
- Multi-block-per-line frequency (assistant content arrays with
  > 1 block).
- Tool-use_id duplicates within a session (across turns; within a
  turn).
- Sidechain (`isSidechain: true`) volume per session.
- `last-prompt` markers per session (and how many correlate with
  rewinds vs are session-resume noise).

### 3. Append findings

**Append to `corpus-survey.md` first** with concrete numbers and
at least one quoted session uuid + line index for any specific
shape claim. Date your additions.

**If the finding affects dispatcher routing**, also update
`claude-jsonl-mapping.md`:

| corpus-survey.md section | mapping.md section to also touch |
|---|---|
| Line types table | §2 (Line type universe) |
| Universal fields | §2 (per-type variants in the table) |
| Content-block shape | §11 (Content-block type reference) |
| Slash-command surfaces | §8 (xml-style tag conventions) |
| Queued-prompt flow | §6 (Per-line dispatch) |
| Rewinds & branching | §7 (Special-case stitching) |
| Wire-shape gotchas | §7 / §8 / §11 depending on shape |
| Sidechain shapes | §6 (sidechain handling stub) |

If you add a new section to corpus-survey.md, decide whether it
needs a mirror in mapping.md. The split is: corpus-survey =
"what's in the JSONL," mapping = "what our code does with it."

### 4. Preserve the audit trail

The maintenance rule on both docs (already documented at the
bottom of corpus-survey.md):

- **Append, don't silently edit.** When a claim is invalidated,
  leave the original line in place and add a correction line
  below: `(Updated YYYY-MM-DD: ...)`.
- **Date everything.** Today's date when you append.
- **Quote evidence.** Concrete numbers (X out of Y sessions / lines),
  at least one concrete session uuid + line index for shape claims.
- **Don't refactor existing entries to "tidy up."** Verbose
  findings preserve methodology. Future readers debugging "why did
  the previous session think X was true?" need the original
  wording + the correction.

## Empirical invariants can be wrong

The first pass of `corpus-survey.md` was authored from one
session's audit run. **The methodology had a ~67% hit rate on
edge-case claims** — two invariants the original audits asserted
were empirically disproved at dogfood time:

1. "Pool buckets have at most 1 child per missing parent" —
   claimed 0/731 sessions; live session crashed on a 2+ case
   within minutes.
2. "Only `attachment.queued_command` consumes queued prompts" —
   slash-command user lines also consume; observed live.

So **treat the doc as a starting point, not gospel.** Always
re-validate before relying on a claim in code that ships. Structure
the code to handle the violation gracefully (array, not
single-value; `if let` not `assert(...)`) rather than asserting an
unverified invariant.

## Don't treat absence as impossibility

The corpus is **user-generated**. The user may simply not have
triggered certain Claude Code features yet — a Codex flow, a
sub-agent spawn pattern, a specific attachment subtype, an obscure
system subtype, a `task-notification`, a multi-rewind sequence, etc.

When you scan and don't find a shape:
- Frame it as **"not observed in N-session sample"** — not
  "doesn't exist" or "impossible."
- The dispatcher / parsers should still handle the unfamiliar
  shape gracefully (log + skip + recover), not crash or
  DEBUG-assert.
- If you're documenting "X is rare" or "X is universal", quote the
  N. Future scans on a richer corpus can re-classify.

## Multi-session convergence

Multiple sessions contribute to the docs. Single-session authorship
is exactly how the two wrong claims above made it in. When
contributing:

- Read what's already there. Don't duplicate findings. If a section
  exists, append a numbered entry under it.
- If you're correcting an earlier claim, **leave the original
  line and add a "(Updated YYYY-MM-DD by [session/agent name]: ...)"
  below**. Don't excise.
- If you find the docs disagree with current code, the **code wins**
  on behavior questions; the docs catch up. (One exception: if the
  code is buggy and the docs describe the spec-correct behavior, the
  docs win and the code gets fixed.)

## Specific scan commands worth saving

Out-of-order parent detection (returns sessions where any line's
parentUuid points later in file order):

```python
import json, glob
for path in glob.glob('~/.claude/projects/**/*.jsonl', recursive=True):
    uuid_idx = {}
    with open(path) as fh:
        lines = [json.loads(l) for l in fh if l.strip()]
    for i, d in enumerate(lines):
        if d.get('uuid'):
            uuid_idx[d['uuid']] = i
    for i, d in enumerate(lines):
        p = d.get('parentUuid')
        if p and p in uuid_idx and uuid_idx[p] > i:
            print(path, i, '->', uuid_idx[p])
```

Multi-child-on-same-parent detection (the invariant that was
wrong):

```python
from collections import defaultdict
# ... iterate sessions, build pending_children = defaultdict(list)
# pending_children[parentUuid] gets appended to each time we see a line
# whose parent appears LATER in file order. count buckets with len > 1.
```

Single-block-per-assistant-line:

```python
total = single = 0
for path in ...:
    for line in ...:
        d = json.loads(line)
        if d.get('type') == 'assistant':
            content = d.get('message', {}).get('content', [])
            if isinstance(content, list):
                total += 1
                if len(content) == 1:
                    single += 1
print(f'{single}/{total} = {100*single/total:.2f}%')
```

Distribution of attachment subtypes:

```python
from collections import Counter
c = Counter()
for path in ...:
    for line in ...:
        d = json.loads(line)
        if d.get('type') == 'attachment':
            c[d.get('attachment', {}).get('type', '<missing>')] += 1
print(c.most_common())
```

Save scan scripts in `/tmp/jsonl-scan/` during a session;
they're disposable. Re-author when needed. The findings are what
get committed — to corpus-survey.md.

## Suggesting parallel updates

When updating `corpus-survey.md`, scan the matching section in
`claude-jsonl-mapping.md` and ask:

- Does the dispatcher currently handle this shape correctly?
- Is the routing table accurate?
- Is the per-line dispatch flow (§6) describing what actually
  happens?
- Are the per-type sub-fields (§2 table) up to date?

If something is stale, fix both. Don't leave the mapping doc
behind — it's the load-bearing reference for new contributors to
the dispatcher. Cross-reference findings with `file:line` so the
implementer knows where to look.

## After every meaningful corpus contribution

Quick sanity check before the session ends:

1. Both docs read coherently end-to-end (no orphan paragraphs).
2. Dates are present on new findings.
3. Concrete numbers + at least one session uuid quoted.
4. Corrections (not silent edits) where applicable.
5. Mapping doc updated if dispatcher behavior is affected.
6. Commit message lists what was added / corrected.
