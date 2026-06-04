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
| `cmux.xcodeproj/project.pbxproj` | adds `Packages/CmuxAgentXray` SPM dependency on the cmux.app target + 6 file refs for `Sources/Panels/AgentXray/*` | merge-pain hotspot; UIDs prefixed `AAAAAAAAAGENTX` (package wiring) and `AGNTRY` (app-side files) to be distinctive |
| `Sources/Panels/Panel.swift` | adds `case agentXray` to `PanelType` + Codable decode fallback for legacy `agentInspector` raw values | low; isolated enum addition |
| `Sources/Panels/PanelContentView.swift` | render arm for `.agentXray` (`CmuxAgentXrayPanelView`); `.agentXray` opted into the pane drop-target overlay | low |
| `Sources/Workspace.swift` | adds `static let agentXray` to `enum SurfaceKind`; `.agentXray` arms in 3 exhaustive switches (snapshot encoding, restoration, surfaceKind(for:)); `requestFlash(panelId:reason:)` fileprivate helper | low; surgical arm additions only |
| `Sources/CmuxLifecycleEventPublishing.swift` | `.agentXray` arm returning `"agent_xray"` event kind | trivial |
| `Sources/Search/GlobalSearchDocuments.swift` | `.agentXray` bundled with the title-only group | trivial |
| `Sources/TerminalPaneDropTargetView.swift` | `.agentXray` arm returning `nil` (no special drop targeting) | trivial |
| `Sources/ContentView.swift` | `.agentXray` arms in 3 switches: command-palette label, command-palette keywords, `cmuxSidebarSurfaceKind` | trivial |
| `Sources/ClosedItemHistory.swift` | `.agentXray` arm with the recently-closed label | trivial |
| `Sources/cmuxApp.swift` | one Debug-menu `Button` invoking `AgentXrayDebugMenu.openAgentXrayInFocusedWorkspace()` | trivial; `#if DEBUG` already wraps the menu |

**Net non-pbxproj surface: 9 files, mostly single-line `case .agentXray:` additions.** The pbxproj itself carries the bulk of the change but is mechanical and pre-merge-resolution-friendly.

---

## App-side adapter files

The cmux-app side adapter lives at `Sources/Panels/AgentXray/`. These
are NEW files (not edits to upstream), so they don't appear in the
upstream-touch table above.

```
Sources/Panels/AgentXray/AgentXrayPanelHost.swift          # Panel-protocol wrapper
Sources/Panels/AgentXray/AgentXrayWorkspaceHost.swift      # AgentXrayHost adapter
Sources/Panels/AgentXray/WorkspaceFocusObserver.swift      # focus-tracking observer
Sources/Panels/AgentXray/WorkspaceScrollbarBridge.swift    # scrollbar bridge
Sources/Panels/AgentXray/Workspace+AgentXray.swift         # Workspace factory + detail routing
Sources/Panels/AgentXray/cmuxApp+AgentXrayDebugMenu.swift  # Debug-menu entry point
```

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
