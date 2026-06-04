# Phase 9 Handover — cmux app integration

This document is the living checklist for completing Phase 9 (host
integration) of the AgentX-ray migration. Phases 1–8, 10, 11, and 13
landed in this branch (`agentxray`); the package is fully self-contained
and `swift build && swift test` are both green at branch tip.

Phase 9 was deferred from the autonomous session that built Phases 7–14
because it requires:

1. **Manual Xcode pbxproj wiring** — adding the local SPM package as a
   dependency on the cmux app target, plus 5 new app-side adapter
   files. Hand-editing `cmux.xcodeproj/project.pbxproj` is high-risk
   (one stray byte corrupts the file); Xcode UI drag-and-drop is the
   safe path.
2. **Cascading enum-arm coverage** — adding `case agentXray` to
   `PanelType` propagates to ~10+ exhaustive switch sites in the cmux
   app target (`Workspace.swift`, `PanelContentView.swift`,
   `ClosedItemHistory.swift`, `MainWindowFocusController.swift`,
   `CmuxLifecycleEventPublishing.swift`, `SettingsNavigation.swift`,
   `DragOverlayRoutingPolicy.swift`, `GhosttyTerminalView.swift`, etc.).
   Each needs a `.agentXray` arm.
3. **End-to-end visual verification** — `./scripts/reload.sh --tag
   agentxray --launch`, then dogfood-clicking the AgentX-ray entry in
   the Debug menu. The autonomous session can't drive that loop.

---

## Concrete Phase 9 checklist

Apply in order. Each numbered step is one logical commit.

### 1. Add SPM dependency on `Packages/CmuxAgentXray` to the cmux app target

In Xcode:
- Open `cmux.xcodeproj`.
- Project navigator → cmux project → Package Dependencies → `+` →
  "Add Local…" → select `Packages/CmuxAgentXray` → Add.
- Cmux app target → Frameworks, Libraries, and Embedded Content →
  add `CmuxAgentXray` library product.

Verify: `git status` shows `cmux.xcodeproj/project.pbxproj` modified;
`xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug
-destination 'platform=macOS' -derivedDataPath /tmp/cmux-agentxray
build` should succeed (no app code referencing the package yet).

Commit message: `Phase 9a: add CmuxAgentXray SPM dependency to cmux target`.

### 2. Add `PanelType.agentXray` and exhaustive switch coverage

Edit `Sources/Panels/Panel.swift`:

```diff
 public enum PanelType: String, Codable, Sendable {
     case terminal
     case browser
     case markdown
     case filePreview = "filepreview"
     case rightSidebarTool
     case project
     case extensionBrowser
+    case agentXray

     public init(from decoder: Decoder) throws {
         let container = try decoder.singleValueContainer()
         let rawValue = try container.decode(String.self)
         if let type = Self(rawValue: rawValue) { self = type; return }
         if rawValue.lowercased() == Self.filePreview.rawValue { self = .filePreview; return }
         if rawValue.lowercased() == Self.rightSidebarTool.rawValue.lowercased() {
             self = .rightSidebarTool; return
         }
+        // Legacy raw value from the spike branch — maps onto agentXray.
+        if rawValue == "agentInspector" { self = .agentXray; return }
         throw DecodingError.dataCorruptedError(...)
     }
 }
```

Then run `xcodebuild build` and follow the error messages — every
exhaustive switch on `PanelType` will need `.agentXray` arm. Audit the
arms by file (find them with `rg "case \.(terminal|browser|markdown):"
Sources/`):

- `Sources/Workspace.swift` — at least 3 switch sites (panel snapshot
  encoding, snapshot restoration, surfaceKindForPanel).
- `Sources/Panels/PanelContentView.swift` — render arm, focus arm.
- `Sources/ClosedItemHistory.swift` — recently-closed label.
- `Sources/MainWindowFocusController.swift` — focus routing.
- `Sources/CmuxLifecycleEventPublishing.swift` — `agent_xray` event kind.
- `Sources/SettingsNavigation.swift` — multiple arms.
- `Sources/DragOverlayRoutingPolicy.swift` — drop targeting.
- `Sources/GhosttyTerminalView.swift` — find any panel-type-keyed branch.
- `Sources/ContentView.swift` — command palette label and keywords.
- `Sources/Search/GlobalSearchDocuments.swift` — search index.

For most arms, the agentXray case behaves like terminal or markdown
(read-only content panel, no search index, no drop target). When in
doubt, fall back to the same behaviour as `.markdown`.

Commit message: `Phase 9b: add PanelType.agentXray + exhaustive arms`.

### 3. Write the app-side adapter files

Create `Sources/Panels/AgentXray/` with 5 files. The previously-deferred
draft for `AgentXrayPanelHost.swift` is worth reviewing — it bridges
`@Observable` AgentXrayPanel to cmux's legacy `Panel` + `ObservableObject`
protocol via a Task-loop on `withObservationTracking`. The final shape
will likely be:

- **`AgentXrayPanelHost.swift`** — `final class AgentXrayPanelHost: Panel,
  ObservableObject`. Owns `let xrayPanel: AgentXrayPanel`. Forwards
  `displayTitle`/`displayIcon`/`close()`/`triggerFlash(reason:)` onto the
  package panel. Maps `WorkspaceAttentionFlashReason` → package
  `AttentionFlashReason`. Listens for `xrayPanel.displayTitle` changes
  via Observation tracking and bumps a `@Published titleTick` so the
  cmux tab bar redraws.

- **`Workspace+AgentXray.swift`** — `extension Workspace: AgentXrayHost`.
  Implements all 7 host-protocol methods:
  - `var workspaceID: UUID` → `id`.
  - `currentFocusedSession()` → drives off `WorkspaceFocusObserver`.
  - `observeFocusChanges(_:)` → returns a `Cancellable` wrapping a
    Combine `AnyCancellable` from `WorkspaceFocusObserver.$current`.
  - `scrollbarSnapshot(forSurfaceID:)` → reads
    `WorkspaceScrollbarBridge.shared.latest(for:)` and wraps the
    `GhosttyScrollbar` into a `ScrollbarSnapshot`.
  - `observeScrollbarChanges(_:)` → adds an
    `NotificationCenter.default.addObserver` for
    `.ghosttyDidUpdateScrollbar`, filters by `surface.id`, fires the
    handler. Returns a `NotificationToken`-flavoured `Cancellable`.
  - `observeClaudeAnchorPayloads(_:)` → adds an observer for
    `.cmuxClaudePromptSubmitted`, extracts `note.claudeAnchorPayload`,
    fires.
  - `openDetailTab(content:fromPanelID:)` → creates a sibling
    AgentXrayPanelHost in the same pane via the `bonsplitController`.
    Returns the new panel's `xrayPanel`.
  - `updateTitle(panelID:title:)` → calls existing `updatePanelTitle`.
  - `flashAttention(panelID:reason:)` → bumps the workspace's flash
    pipeline.

  Plus add `newAgentXraySurface(inPane:focus:targetIndex:)` and
  `splitPaneWithAgentXray(targetPane:orientation:insertFirst:)` factory
  methods that create AgentXrayPanelHost instances and route through
  bonsplit. Mirror the spike's
  `Workspace+AgentInspector.swift` shape (now in
  `cmux-swiftui/Sources/Panels/AgentInspector/Workspace+AgentInspector.swift`).

- **`WorkspaceFocusObserver.swift`** — port from
  `cmux-swiftui/Sources/Panels/AgentInspector/Attach/FocusedSurfaceObserver.swift`.
  Watches three notifications (`.ghosttyDidFocusSurface`,
  `.ghosttyDidFocusTab`, `.ghosttyDidBecomeFirstResponderSurface`),
  resolves the focused surface, calls `AgentSessionResolver.resolve(...)`,
  publishes `@Published var current: ResolvedAgentSession?` for the
  Workspace conformance to consume. Phase 12 replaces the Combine
  publisher with an `AsyncStream`-based pipeline; for Phase 9 keep it
  Combine-flavoured.

- **`WorkspaceScrollbarBridge.swift`** — port from
  `cmux-swiftui/Sources/Panels/AgentInspector/Sync/ScrollbarStateCache.swift`.
  Singleton subscribed to `.ghosttyDidUpdateScrollbar`; stores
  `[UUID: ScrollbarSnapshot]` (project the GhosttyScrollbar into the
  package's value type at the boundary). Workspace conformance reads
  via `latest(for:)`.

- **`cmuxApp+AgentXrayDebugMenu.swift`** — DEBUG-build menu entry.
  Adds an item to the Debug menu that calls a new
  `Workspace.newAgentXraySurface(...)` factory, opening a live AgentX-ray
  tab in the focused pane.

- **`AgentXraySurfaceKind.swift`** — adds a `SurfaceKind.agentXray`
  case (for tab bar identity), restoration plumbing, and search-index
  exclusion. Mirror the spike file at
  `cmux-swiftui/Sources/Panels/AgentInspector/SurfaceKind+AgentInspector.swift`
  (if present) or whichever location the cmux project uses for
  per-surface-kind metadata.

After creating each file, drag it into `cmux.xcodeproj` in Xcode (cmux
target membership). The pbxproj diff will show four entries per file
(`PBXFileReference`, `PBXBuildFile`, `PBXSourcesBuildPhase` membership,
group membership).

Commit message: `Phase 9c: app-side AgentXray adapter`.

### 4. Wire `PanelContentView.swift` render arm

```diff
 case .agentXray:
     if let host = panel as? AgentXrayPanelHost {
         AgentXrayPanelView(...)
             .environmentObject(host)
     } else {
         EmptyView()
     }
```

The actual `AgentXrayPanelView` lives in the package; PanelContentView
constructs it with the right inputs (`panel.xrayPanel`,
`isFocused`, `appearance`, etc.). See the spike's
`AgentInspectorPanelView` for the parameter shape.

NOTE: the package does NOT currently ship a top-level `AgentXrayPanelView`
view (Phase 7 only ships the per-row `EntryView`). Phase 9 needs to
write a transcript-list view that consumes `AgentXrayPanel.stream.entries`
and renders rows. Port this from
`cmux-swiftui/Sources/Panels/AgentInspector/AgentInspectorPanelView.swift`
into the package as `Views/PanelView.swift`. This was deferred from
Phase 7 because it depends on Phase 8's panel API surface.

Commit message: `Phase 9d: PanelContentView render arm + package PanelView`.

### 5. Build + dogfood

```bash
./scripts/reload.sh --tag agentxray --launch
```

In the launched app:
1. Debug menu → Agent X-ray → New Agent X-ray surface.
2. Focus a terminal running `claude` or `codex`.
3. Confirm the panel attaches to the focused session.
4. Bulk expand/collapse pills work.
5. `.snap` ↔ `.free` mode flip works.
6. `↗ Open detail` link opens a sibling tab in the same pane.

If the build fails, iterate on switch arms or pbxproj refs.

### 6. Update plan & ledger

After Phase 9 lands:
- Mark §1 row 9 ✅ in `~/.claude/plans/agentxray-migration-2026-06-04.md`.
- Append a Phase 9 progress-log entry to §14.
- Append any new bug fixes encountered to §15.
- Update `Packages/CmuxAgentXray/FORK_NOTES.md` with the actual
  upstream-touch table (one row per file).

---

## Phase 12, 14, 15, 16

Phase 12 (AsyncStream focus pipeline) is a Phase 9-side refinement;
fold it in once Phase 9 builds.

Phase 14 (final docs pass) and Phase 15 (cleanup) are package-side
once the host integration validates.

Phase 16 (whole-package audit) runs after Phase 15. The user explicitly
asked for it: "audit the whole AgentXray code to catch any problems
and inconsistencies and missed points. See if we also achieved our
refactoring and sweeping goals."
