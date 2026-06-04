# `Sources/Panels/AgentXray/` — cmux-side adapters for the AgentX-ray feature

This folder is the cmux-app-target seam for the **AgentX-ray** feature
implemented in the `Packages/CmuxAgentXray/` Swift package.

## Architecture

```
Packages/CmuxAgentXray/  (self-contained SPM package — no cmux imports)
   ↑     defines protocols + value types the host must provide
   |
   |     conformed-to / consumed by:
   ↓
Sources/Panels/AgentXray/  (this folder — cmux-app target)
   ↑     reaches into Workspace, TerminalPanel, Bonsplit, Ghostty, etc.
```

The package owns *what to do* (models, streaming, behaviour, views,
the `@Observable AgentXrayPanel` ViewModel). This folder owns *how to
talk to cmux* — Workspace shape, AppKit notifications, the cmux `Panel`
protocol, Ghostty types, Bonsplit tab plumbing.

The package never imports cmux-app types. Every cross-domain
interaction passes through the package's `AgentXrayHost` protocol,
which is implemented here.

## Files

### `AgentXrayPanelAdapter.swift`

**One per AgentX-ray panel. Conforms to cmux's `Panel` protocol.**

cmux's `Panel` protocol requires `ObservableObject` conformance
(Combine). The package's `AgentXrayPanel` deliberately uses
`@Observable` (Observation framework). The two patterns don't
cross-conform, so this adapter wraps the package panel: it holds a
strong reference to it and forwards every `Panel`-protocol method onto
it. Title changes are bridged via a Task-loop on
`withObservationTracking` that bumps a `@Published titleTick` so cmux's
tab bar redraws.

On `init`, registers itself with the workspace's `AgentXrayWorkspaceHost`
panel registry. On `close()`, deregisters.

### `AgentXrayWorkspaceHost.swift`

**One per `Workspace` (lazy-init). Conforms to the package's
`AgentXrayHost` protocol.**

This is the concrete adapter the package interacts with. All
AgentX-ray panels in one workspace share this single host — three
panels do not produce three observers.

Composes four pipelines, each a `MARK:` section in the file:

- **Focus + session resolution** — bridges `Workspace.objectWillChange`
  into an `AsyncStream<Void>` with 150 ms trailing-debounce; observes
  three focus notifications (`.ghosttyDidFocusSurface`,
  `.ghosttyDidFocusTab`, `.ghosttyDidBecomeFirstResponderSurface`);
  calls `AgentSessionResolver` and emits a `ResolvedAgentSession?`
  via `@Published currentFocus`.

- **Scrollbar pipeline** — caches the latest `ScrollbarSnapshot` per
  surface (projected from cmux's internal `GhosttyScrollbar` to the
  package's neutral value type), observes `.ghosttyDidUpdateScrollbar`,
  multicasts to per-panel subscribers.

- **Claude anchor pipeline** — observes `.cmuxClaudePromptSubmitted`,
  decodes payloads, multicasts to per-panel subscribers.

- **Per-panel routing** — holds a `[UUID: WeakPanelAdapterBox]` registry
  so the package's per-panel `AgentXrayHost` methods (`openDetailTab`,
  `updateTitle`, `flashAttention`) can dispatch to the right adapter
  given the `panelID` argument.

Also contains the `HostCancellable` token type used by the protocol's
observation methods — small adapter sibling, lives in this file rather
than its own.

### `Workspace+AgentXray.swift`

**Workspace-side factory methods + detail-tab routing helper.**

Three factories (`splitPaneWithAgentXray`, `newAgentXraySurface`,
`openAgentXrayDetail`) construct `AgentXrayPanelAdapter` instances and
wire them into the workspace's `panels` dictionary, `surfaceIdToPanelId`
mapping, and Bonsplit tab/pane structure. The detail-tab routing helper
is invoked from `AgentXrayWorkspaceHost.openDetailTab(...)` when a row's
`↗ Open detail` link fires.

These live as a `Workspace` extension because they do Workspace
bookkeeping that's natural to express on the Workspace itself.

## Lifecycle

```
Workspace
  ├── _agentXrayWorkspaceHost: AnyObject?           (lazy-init in Workspace.swift)
  │       ↓ accessor: agentXrayWorkspaceHostLazy()
  │   AgentXrayWorkspaceHost (workspace-scoped)
  │       ├── focus pipeline
  │       ├── scrollbar pipeline
  │       ├── anchor pipeline
  │       └── panel registry: [UUID: weak AgentXrayPanelAdapter]
  │
  └── panels: [UUID: any Panel]
        ├── AgentXrayPanelAdapter (per-panel; borrows the host above)
        │       └── xrayPanel: AgentXrayPanel  (package ViewModel)
        ├── AgentXrayPanelAdapter (another panel in the same workspace,
        │                          shares the same host)
        └── ...
```

## Conventions

- **No new symbols leak cmux-internal types into the package.** The
  package's protocols and value types are the only surface visible
  across the seam.
- **One major type per file**, with the carve-out for tightly-bound
  helpers (`HostCancellable` lives next to `AgentXrayWorkspaceHost`
  because it's a single-purpose protocol-conformance sibling).
- **`@available(macOS 15, *)`** on every type in this folder. The
  package's platform floor is macOS 15 and we don't add fallback paths.
- **No `static let shared`** singletons. Workspace lifecycle is the
  scoping unit; pipelines that previously used singletons (the
  scrollbar bridge) have been folded into the workspace host.

## See also

- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Host/AgentXrayHost.swift`
  — the protocol this folder implements.
- `Packages/CmuxAgentXray/README.md` — package overview.
- `Packages/CmuxAgentXray/FORK_NOTES.md` — upstream-touch ledger
  (which cmux files this folder requires changes to).
