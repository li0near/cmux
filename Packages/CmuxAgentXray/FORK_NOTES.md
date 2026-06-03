# CmuxAgentXray — Fork Notes

Tracked upstream-touch ledger for the AgentX-ray fork-side feature. The
package itself (`Packages/CmuxAgentXray/`) is fully self-contained and
contributes **zero** to upstream-touch surface. This file lists every
edit to upstream-tracked files outside the package that supports
AgentX-ray.

**Goal:** keep this list as small as possible. Each row is one upstream
file with one or two lines of diff content. Re-verify after every
upstream pull.

---

## Re-verification command

```bash
git fetch upstream main
git diff --name-status upstream/main | grep -v '^A.*Packages/CmuxAgentXray'
```

That prints every non-package file that diverges from `upstream/main`. Every
row that prints should appear in the table below; any new row needs a new
table entry (and a "is this really necessary?" check).

---

## Upstream-touch surface

Last verified against `upstream/main` at `81e409c35` on **2026-06-04**.

| File | Current change | Risk |
|---|---|---|
| _(none yet — Phase 1 added only the package itself)_ | | |

This table fills out across migration phases 9–10 as the host adapter is
wired in. Target end state: ~13 small switch-arm additions, all listed
in the migration plan §8.

---

## Package-owned files

All tracked Swift implementation under `Packages/CmuxAgentXray/Sources/`
and `Packages/CmuxAgentXray/Tests/` is package-owned and does not appear
in the upstream-touch table above.

```text
Packages/CmuxAgentXray/Package.swift
Packages/CmuxAgentXray/README.md
Packages/CmuxAgentXray/FORK_NOTES.md            # this file
Packages/CmuxAgentXray/Sources/CmuxAgentXray/**/*.swift
Packages/CmuxAgentXray/Sources/CmuxAgentXray/Resources/Localizable.xcstrings
Packages/CmuxAgentXray/Tests/CmuxAgentXrayTests/**/*.swift
```

App-side adapter files at `Sources/Panels/AgentXray/` are listed in the
table above (cmux project file additions; they are new files, not edits to
upstream content).

---

## Reapplying after an upstream pull

1. Pull or merge `upstream/main`.
2. Re-run the verification command at the top of this file.
3. For every row in the table, confirm the diff still reflects the
   intended one-line addition. Conflicts on switch arms are common — keep
   the AgentX-ray case alongside any new upstream cases.
4. Re-check `cmux.xcodeproj/project.pbxproj` SPM dependency block:
   `CmuxAgentXray` library product reference must remain present on the
   `cmux` app target.
5. Re-run package tests:
   ```bash
   swift test --package-path Packages/CmuxAgentXray
   ```
6. Build the tagged Debug app:
   ```bash
   PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
   CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
   ./scripts/reload.sh --tag agentxray
   ```

---

## Local docs

Everything personal/in-progress lives outside this package:

- Migration plan + status: `~/.claude/plans/agentxray-migration-2026-06-04.md`
- Spike reference: `agent-inspector-swiftui-spike` branch (preserved as
  historical reference; never merged).
