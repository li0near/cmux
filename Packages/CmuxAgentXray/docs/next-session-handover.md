# AgentX-ray — pending work handover (RETIRED)

**SUPERSEDED — 2026-06-07.**

All five Tier 3/4/5 items tracked here (T3.1, T3.2, T4.1, T5.1, T5.2)
landed in Phases A–E of the 2026-06-07 refactor. The canonical commit
ledger is now **`MIGRATION_PLAN.md` §14 rows 19j–19n**.

For pending items going forward (deferred-by-policy, gated-on-upstream-
work, or future feature ideas), consult **`MIGRATION_PLAN.md` §16**.

---

## Tier 3/4/5 landings (snapshot, for searchability)

| Item | Phase | Commit |
|---|---|---|
| T3.1 — `DetailContent.Kind` → `ContentType` swap | A | `65b0498b4` (+ `b3456f9cb` fix) |
| T4.1 — `Section` richness (`.image`, `.toolReference`) + `flattenToolResult` rewrite | B | `628b9fe4b` … `f3d006395` |
| T3.2 — `<persisted-output>` wrapper detection | C | `5fd81d2b3`, `20066fd21` |
| T5.2 — `ContentType` foundation extension | D | `843384994` |
| T5.1 — Source-aware shape-sniff content split | E | `81971aa5a` |

## Cross-doc map (current)

| Doc | What it covers |
|-----|----------------|
| `README.md` | Package overview, vocabulary, layer map, host integration. |
| `MIGRATION_PLAN.md` | Phase log + bug-fix ledger + deferred-task ledger. §14 rows 19a–19n trace the whole refactor; §16 carries forward-looking deferrals. |
| `docs/claude-jsonl-mapping.md` | How Claude JSONL maps to entries (parser tree + table + maintenance guide). Updated 2026-06-07 with the canonical block-type table from the spec audit + the dual-parent image fact + `tool_reference` parent fact. |
| `docs/session-attach.md` | Session-attach resolver flow (paths 1/2/3, SSH attach, `RemoteSessionStore`). |
| `docs/next-session-handover.md` | **(this doc — RETIRED)** All listed items landed; future deferrals live in `MIGRATION_PLAN.md` §16. |

If any doc disagrees with the code, the code wins — fix the doc in the same change.
