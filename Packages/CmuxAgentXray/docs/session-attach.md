# Session Attach Resolution

How AgentX-ray decides **which Claude / Codex session is running in the
currently focused terminal**, and how it streams that session's
transcript into the panel.

`AgentSessionResolver`
(`Sources/CmuxAgentXray/Streaming/AgentSessionResolver.swift`) is the
single decision point. It joins state cmux already maintains as
authoritative — no host-wide process-tree scan, no argv scraping, no
mtime heuristics. Three resolution paths run in priority order; the
first one that yields a usable session wins.

## Three paths at a glance

1. **Restored snapshot** — auto-resume after cmux restart.
2. **Live PID + hook record** — fresh panels, `/new` mid-session.
3. **Remote attach (claude only)** — SSH terminals where the user has
   pasted a session id into the inline prompt.

---

## High-level state machine

```
┌──────────┐  resolver returns     ┌─────────┐  first line ingested  ┌────────────┐
│ Detached │ ──── ResolvedAgentSession ────▶ │ Hooked  │ ───────────────────────▶ │ Streaming  │
└──────────┘     (transcriptPath valid)      └─────────┘    (entries non-empty)   └────────────┘
     ▲                                            │
     │                                            ▼
     │                              ┌──────────────────────────┐
     │                              │ TranscriptStream.attach  │
     │                              │   .local  → JSONLTail    │
     │                              │   .remote → RemoteJSONL  │
     │                              │            Stream        │
     │                              └──────────────────────────┘
     │
     └── focus moves away / panel close / "Change" link / hook record cleared
```

Status-bar dot color (`Views/StatusBarView.swift`):

| Color  | Stage                                | Trigger                                                                       |
|:-------|:-------------------------------------|:------------------------------------------------------------------------------|
| RED    | `.idle` / `.awaitingSession`         | `resolvedSession == nil`, OR a stream error overrides everything              |
| YELLOW | `.streamingNoEntries`                | `resolvedSession != nil`, entries empty (Hooked but waiting)                  |
| GREEN  | `.streaming(turns:tokens:)`          | At least one Entry has been ingested                                          |

---

## Resolver decision tree

```
focus event (debounced 150 ms by AgentXrayWorkspaceHost.focus pipeline)
        │
        ▼
┌──────────────────────────────────────┐
│ AgentSessionResolver.resolve(panel)  │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│ Path 1: restored-snapshot synthesis  │
│ host.restoredAgentSnapshot(panelID)? │
└──────┬─────────────────────┬─────────┘
       │ found               │ nil
       ▼                     │
build claude transcript      │
path from (cwd, sid);        │
return synthesized           │
ResolvedAgentSession.local   │
                             ▼
                ┌──────────────────────────────────────────┐
                │ Path 2: live PID + hook record           │
                │ for pid in host.agentPIDs(panelID):      │
                │   match = host.findAgentHookRecord(pid)  │
                │   if match.transcriptPath ∈ {nil, ""}:   │  ← skip incomplete records
                │       continue                           │     (Phase 18 regression fix)
                │   return synthesized                     │
                │   ResolvedAgentSession.local             │
                └──────┬─────────────────────┬─────────────┘
                       │ matched             │ no match
                       ▼                     │
              return synthesized             │
              ResolvedAgentSession.local     │
              (sessionID + cwd +             │
              transcriptPath from            │
              the hook record)               ▼
                              ┌──────────────────────────────────────────┐
                              │ Path 3: remote attach (manual session id)│
                              │ host.currentTerminalRemoteContext()?     │
                              │   ctx with non-empty remoteHome AND      │
                              │   ctx.agentKind == .claude AND           │
                              │   stored remoteSession id?               │
                              └──────┬─────────────────────┬─────────────┘
                                     │ all present         │ any missing
                                     ▼                     │
                          synthesize absolute              │
                          remote transcriptPath:           │
                          <remoteHome>/.claude/projects/   │
                          <encoded-cwd>/<sid>.jsonl        │
                          return synthesized               │
                          ResolvedAgentSession.remote(_:)  │
                                                           ▼
                                                          nil
                                                       (Detached)
```

| # | Path | Source-of-truth | Handles |
|---|---|---|---|
| 1 | Restored snapshot | `Workspace.restoredAgentSnapshotsByPanelId[panelID]` — cmux's session-restoration index, pre-mapped onto the fresh panel UUID at restore time | Auto-resume after cmux restart, before agent has spawned or its hook has fired |
| 2 | Live PID + hook record | `CmuxTopProcessSnapshot.captureCached(...).pids(forCMUXSurfaceID:)` reading `CMUX_SURFACE_ID` env vars set at shell spawn, joined by PID against `~/.cmuxterm/{claude,codex}-hook-sessions.json` | Fresh panels post-boot, `/new` mid-session (hook record upserts; live record beats stale snapshot) |
| 3 | Remote attach (claude only) | `host.currentTerminalRemoteContext()` (workspace-level SSH OR per-tab inferred ssh) + cached remote `$HOME` + persisted user-supplied session id from `RemoteSessionStore` | SSH terminals running `claude --resume <id>` where the user has typed the id into the inline prompt at least once |

---

## Path 1 timing — auto-resume after cmux restart

```
cmux app restart  shell spawned   agent spawned    SessionStart hook
                  (env injected)  (--resume id)    fires
     │                │                │                │
     │           [Path 1 hits ─────────────────────▶]   │
     │                │                │                │
     │                │            [Path 2 hits ──────▶]
     ▼                ▼                ▼                ▼
   t = 0          ~few-100 ms      ~few-100 ms        ~1 s
```

Path 1 attaches the panel **before the agent process exists**. The
synthesized transcript path may not be on disk yet — `JSONLTail` handles
missing files via exponential-backoff open retries (1, 2, 4, 8, 16, 32,
30, 30 s) and starts streaming the moment the agent creates the file.

Path 2 takes over once the hook record is on disk and continues to
reflect every subsequent `/new`-style session change.

---

## Path 2 — the "hook before first prompt" interaction

Phase 18 (commits `533f18949` + `31a7654ca`) replaced argv scraping
and process inspection with a direct read of the cmux CLI's hook
records. claude's SessionStart hook fires *immediately* when claude
starts (bare `claude`, no `--resume`, no prompt yet) — fast enough that
the panel can hook before the user ever types.

But claude's SessionStart hook does **not** always disclose
`transcript_path` (the .jsonl path may not exist or may not yet be
known). The hook record gets `transcriptPath: nil`, and the resolver
must skip it — otherwise the panel renders "Hooked" while
`TranscriptStream.attach` early-returns on the empty path, leaving
nothing observing the file.

```
Bare `claude` start
        │
        ▼
SessionStart hook fires      ┌─ Hook record now contains:
        │                    │     sessionId = X
        ▼                    │     pid       = <claude_pid>
cmux CLI writes record ──────┤     cwd       = <cwd>
                             │     transcriptPath = nil  ← may be nil!
                             └─
        │
        ▼
storeWatcher (vnode source on claude-hook-sessions.json) fires
        │
        ▼
recompute()  →  resolver.resolve(panelID)
        │
        ▼ (path 1 nil; path 2 finds claude_pid → match)
        │
        ▼
match.transcriptPath ∈ {nil, ""} ?
        │
        ├─ YES → continue (skip this match)        ─▶ Detached
        │       (no other PIDs match either)
        │       Panel stays Detached. JSONLTail
        │       is NOT created. No phantom listener.
        │
        ▼ NO
return ResolvedAgentSession.local with valid path ─▶ Hooked → Streaming
```

When the user later sends a prompt, claude's prompt-submit hook fires
**with** `transcript_path`. The cmux CLI calls `upsertSessionRecord`
which updates the existing record's `transcriptPath` field. The store
watcher fires again, recompute runs, path 2 now hits cleanly, and the
panel attaches + streams.

```
User sends first prompt
        │
        ▼
claude's prompt-submit hook fires (now carries transcript_path)
        │
        ▼
cmux CLI's upsertSessionRecord(...) updates record:
   transcriptPath: nil → "/Users/x/.claude/projects/.../X.jsonl"
        │
        ▼
storeWatcher fires (vnode .write on claude-hook-sessions.json)
        │
        ▼
recompute()  →  path 2 returns ResolvedAgentSession with valid path
        │
        ▼
updateIfChanged: key changes → emit currentFocus
        │
        ▼
panel.handleSessionChange → TranscriptStream.attach
        │
        ▼
attachLocal: read existing file content (the user line claude just
wrote), spawn JSONLTail at offset N, install vnode watch for appends
        │
        ▼
Subsequent agent response writes → vnode .extend → drain → emit lines
→ ingest → entries grow → panel updates → Streaming (GREEN)
```

This restored the pre-Phase-18 "Detached until first prompt" UX for the
bare-`claude` case while keeping the immediate-attach win for paths 1
and `--resume`.

---

## Path 3 — manual SSH attach

For SSH-backed terminals (workspace-level remote OR per-tab `ssh`
subprocess), cmux's local hook records don't exist (the hook runs on
the remote host's claude, not on the Mac). Path 3 lets the user paste a
remote claude session id into an inline prompt; the panel persists it
and streams the remote transcript via SSH.

### End-to-end flow

```
AgentX-ray panel opens, focused terminal is on SSH
        │
        ▼
┌──────────────────────────────────────────────────┐
│ host.currentTerminalRemoteContext()              │
│   1. sshTransportForTerminal(focusedTerminal)    │
│      a. inferSSHTransportFromProcessTree         │  ← per-tab ssh detection
│         (TerminalSSHSessionDetector)             │
│      b. fallback: workspace.remoteConfiguration  │  ← workspace-level remote
│   2. RemoteHomeResolver.cached(transport)        │
└────┬─────────────────────────────────────────────┘
     │ ctx (transport, cwd, remoteHome="" when uncached)
     ▼
panel.canShowRemoteAttachPrompt → renders RemoteAttachPromptView
┌──────────────────────────────────────────────────┐
│ "Set Claude session id"                          │
│ "Attaching to <destination>. Run                 │
│  `claude --resume <id>` on the remote and paste  │
│  the id below."                                  │
│ [<TextField>] [Attach]                           │
└────┬─────────────────────────────────────────────┘
     │ user pastes id, clicks Attach
     ▼
panel.setRemoteClaudeSessionID("session-uuid")
     │  (sets remoteAttachInFlight = true)
     ▼
host.attachRemoteClaudeSessionID("session-uuid")
     │
     ▼ async Task @MainActor
┌──────────────────────────────────────────────────┐
│ 1. RemoteHomeResolver.resolve(transport)         │
│    spawns `ssh -o ControlPath=<cmux master>      │
│             -o ControlMaster=no                  │
│             <destination> echo $HOME`            │
│    caches result in UserDefaults keyed by        │
│    (destination, port, identityFile, controlPath)│
│ 2. RemoteSessionStore.write(destination, cwd,    │
│    .claude, "session-uuid")  →  UserDefaults     │
│ 3. recompute()                                   │
└────┬─────────────────────────────────────────────┘
     │
     ▼
resolver.resolve(panelID)
     │
     ▼ paths 1 & 2 nil (terminal is SSH'd, no local hook)
     ▼ path 3 hits: ctx now has cached remoteHome
┌──────────────────────────────────────────────────┐
│ ResolvedAgentSession(                            │
│   transport: .remote(SSHTransport),              │
│   transcriptPath:                                │
│     <remoteHome>/.claude/projects/               │
│     <encoded-cwd>/<sid>.jsonl                    │
│ )                                                │
└────┬─────────────────────────────────────────────┘
     │
     ▼
panel.handleSessionChange → TranscriptStream.attach
     │
     ▼
attachRemote: spawn RemoteJSONLStream
┌──────────────────────────────────────────────────┐
│ Process: /usr/bin/ssh                            │
│ argv:    -T                                      │
│          -o ControlPath=<cmux master template>   │  ← rides cmux's
│          -o ControlMaster=no                     │     existing master
│          -o ServerAliveInterval=15               │     connection
│          -o ServerAliveCountMax=4                │
│          <destination>                           │
│          stdbuf -oL tail -n +1 -F -- '<path>'    │
└────┬─────────────────────────────────────────────┘
     │
     ▼
stdout lines (newline-framed via JSONLLineFramer for UTF-8 safety)
     │
     ▼
ingest → builder → entries grow → Streaming (GREEN)
```

### Key shapes

| Type | File | Persistence key | Purpose |
|---|---|---|---|
| `RemoteSessionStore` | `Streaming/RemoteSessionStore.swift` | `agentXray.remote.session.<sha256(destination\|cwd\|kind)>` | Stores user-pasted session ids per (destination, cwd, agentKind). Survives workspace renames + UUID resets. |
| `RemoteHomeResolver` | `Sources/Panels/AgentXray/RemoteHomeResolver.swift` | `agentXray.ssh.home.<sha256(dest\|port\|id\|controlPath)>` | Caches `$HOME` per SSH endpoint so synthesized paths are absolute (no tilde leaves cmux). |
| `RemoteAttachContext` | `Streaming/RemoteAttachContext.swift` | _(value type, not persisted)_ | Snapshot passed to `AgentSessionResolver` path 3 closures. Empty `remoteHome` suppresses path 3 but lets the prompt still render. |

### Per-tab SSH inference

`AgentXrayWorkspaceHost.inferSSHTransportFromProcessTree(panelID:)`
catches the case where the user typed `ssh user@host` inside an
otherwise-local terminal — even though `Workspace.remoteConfiguration`
is nil:

```
host.agentPIDs(forPanelID:) → CmuxTopProcessSnapshot.pids(forCMUXSurfaceID:)
        │ all live PIDs in the panel's process tree
        ▼
sort descending (highest PID first → innermost ssh wins)
        │
        ▼
for pid in sortedPIDs:
   args = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: pid)
   if basename(argv[0]) == "ssh":
       detected = TerminalSSHSessionDetector.parseSSHCommandLine(argv)
       return SSHTransport(
           destination: detected.destination,
           port: detected.port,
           identityFile: detected.identityFile,
           controlPath: detected.controlPath
       )
fallthrough → workspace-level workspace.agentXraySSHTransport()
fallthrough → nil (fully local)
```

When the user `exit`s the SSH session, the ssh PID disappears from the
snapshot (1.5 s TTL). The next focus event resolves the context to
nil → path 3 stops firing → panel detaches naturally.

### "Change" affordance

When `panel.resolvedSession?.transport` is `.remote(_:)` (the unique
signature of path 3), `StatusBarView` renders a compact "Change" link
beside the attached title. Tapping calls
`panel.setRemoteClaudeSessionID(nil)` → host clears the
`RemoteSessionStore` entry + recompute → resolver returns nil → panel
detaches → `RemoteAttachPromptView` re-renders for re-entry.

### ControlPath piggyback

`Workspace.agentXraySSHTransport()` extracts the ControlPath template
(`/tmp/cmux-ssh-<uid>-%C` or relay-port variant) from
`workspace.remoteConfiguration.sshOptions` via the same precedent used
by `WorkspaceRemoteSSHBatchCommandBuilder`. Both `RemoteHomeResolver`
and `RemoteJSONLStream` pass `-o ControlPath=<template>` plus
`-o ControlMaster=no` when `transport.controlPath` is non-nil — the
ssh subprocess runs as a slave and rides the multiplexed connection
cmux already has open for the workspace's terminals (no fresh auth
round-trip).

Per-tab inferred transports leave `controlPath: nil` (the user's manual
`ssh user@host` doesn't share cmux's master), so AgentX-ray's
subprocesses open their own connection in that case. v1 limitation.

---

## Stable across cmux restart

Both path-1 and path-2 sources deliberately survive cmux app restart:

| Signal | Survives restart? | Why it's load-bearing |
|---|---|---|
| `Workspace.restoredAgentSnapshotsByPanelId[panelID]` | ✅ rebuilt from cmux's session snapshot | Path 1 fires before any agent process exists |
| `~/.cmuxterm/{claude,codex}-hook-sessions.json` | ✅ on-disk JSON | Path 2's hook record persists across cmux restart |
| `CmuxTopProcessSnapshot` env-var-scoped scan | ✅ reads live `CMUX_SURFACE_ID` env vars set at shell spawn | Catches surviving claude processes that `set_agent_pid` doesn't |
| `RemoteSessionStore` (UserDefaults) | ✅ UserDefaults persistence | Path 3 auto-attaches on next panel open with cached id |
| `RemoteHomeResolver` cache (UserDefaults) | ✅ UserDefaults persistence | Avoids re-running `ssh exec echo $HOME` for known endpoints |

Volatile signals deliberately **not used** as load-bearing:

- `Workspace.id` / `Panel.id` UUIDs — freshly minted on every launch.
- `Workspace.agentPIDs` registry — in-memory; only populated by
  `set_agent_pid` during `SessionStart`, empty for surviving processes
  after restart. Replaced by env-var-scoped `CmuxTopProcessSnapshot`
  scanning in commit `31a7654ca`.
- Per-record `(workspaceId, surfaceId)` keys in the hook store — stale
  post-restart because the workspace UUID changes; resolver joins by
  PID instead.

---

## Failure modes

| Symptom | Cause | Resolution |
|---|---|---|
| Panel stays "Detached" briefly after claude starts | Hook hasn't fired yet (sub-second) | Resolves on next focus event when storeWatcher fires |
| Panel stays "Detached" indefinitely | Hook handler misconfigured (hook script failing) or hook record never written | Investigate cmux hook setup; AgentX-ray won't fabricate a session |
| Two agents in one panel | Multiple `ssh` / claude processes in the panel's tree | First PID with a hook record wins; per-tab SSH inference picks innermost ssh |
| Bare `claude` shows "Hooked" but never streams (pre-fix Phase 18) | Hook record's `transcriptPath` was nil at SessionStart; resolver returned a session anyway | **Fixed** in commit `4e1dcdf2c`: path 2 skips records with nil/empty `transcriptPath`. Panel stays Detached until prompt-submit hook updates the path. |
| Remote SSH panel shows "Detached" with no prompt | `Workspace.remoteConfiguration` is nil AND no `ssh` subprocess detected in the focused terminal | Ensure the terminal is actually SSH'd and that the `ssh` argv parses cleanly |
| Remote SSH panel "Hooked" but never streams | User-supplied session id is wrong, or claude on the remote is writing to a different path | Click "Change" in the status bar to re-enter; verify the remote `claude --resume <id>` is using the same id |
| Streaming stalls mid-session | Network drop / SSH connection killed | `RemoteJSONLStream` retries up to 8× with exponential backoff (`1, 2, 4, 8, 16, 32, 30, 30 s`); ControlMaster reuse minimizes reconnect cost |

---

## File reference

| Concern | File |
|---|---|
| Resolver entry point + path 1 / 2 / 3 | `Sources/CmuxAgentXray/Streaming/AgentSessionResolver.swift` |
| Local file tail (path 1 / 2) | `Sources/CmuxAgentXray/Streaming/JSONLTail.swift` |
| Remote `ssh exec tail -F` (path 3) | `Sources/CmuxAgentXray/Streaming/RemoteJSONLStream.swift` |
| Line framing (UTF-8 boundary safety) | `Sources/CmuxAgentXray/Streaming/JSONLLineFramer.swift` |
| Stream dispatch + per-kind builder | `Sources/CmuxAgentXray/Streaming/TranscriptStream.swift` |
| Hook record store | `Sources/CmuxAgentXray/Adapters/Claude/ClaudeHookSessionStore.swift`, `Sources/CmuxAgentXray/Adapters/Codex/CodexHookSessionStore.swift` |
| Persistent remote session ids | `Sources/CmuxAgentXray/Streaming/RemoteSessionStore.swift` |
| Remote attach context value type | `Sources/CmuxAgentXray/Streaming/RemoteAttachContext.swift` |
| App-side host (focus pipeline + recompute + remote handlers) | `Sources/Panels/AgentXray/AgentXrayWorkspaceHost.swift` |
| Remote `$HOME` resolver | `Sources/Panels/AgentXray/RemoteHomeResolver.swift` |
| Inline prompt view | `Sources/CmuxAgentXray/Views/RemoteAttachPromptView.swift` |
| Status-bar "Change" link | `Sources/CmuxAgentXray/Views/StatusBarView.swift` |
| Panel ViewModel (state + actions) | `Sources/CmuxAgentXray/Panel/AgentXrayPanel.swift`, `AgentXrayPanel+Streaming.swift`, `AgentXrayPanel+RemoteAttach.swift` |
