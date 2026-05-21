# Restored Claude sessions bypass the cmux wrapper

> Draft for an upstream PR / issue. Captures the problem, the existing
> architecture, the failure mode, and the proposed minimal fix. Tested on
> macOS 14.x with the user's tagged debug build of cmux.

## TL;DR

When cmux relaunches and auto-resumes Claude sessions, the spawned
`claude` process invokes the absolute path captured in the hook store
(typically `/opt/homebrew/bin/claude`) rather than going through cmux's
own wrapper at `Contents/Resources/bin/claude`. Because the wrapper is
how `--session-id` and `--settings` get injected, **SessionStart hooks
never fire for restored Claude sessions**. Downstream consequences:

- Hook records in `~/.cmuxterm/claude-hook-sessions.json` are not
  refreshed for restored sessions until the user takes a turn that
  triggers Stop or another hook.
- The Agent Inspector and any other consumer that keys off the hook
  store sees stale or missing records.
- `claude --resume` invocations in argv lack `--session-id` /
  `--settings`, even when CLI integration is enabled.

The fix is one Swift file (`Sources/RestorableAgentSession.swift`),
~25 lines including comment, scoped to `case .claude:` in
`resumeArguments`. It does not alter restoration for any other agent.

## Repro

1. Open cmux.
2. Start `claude` in any cmux-launched terminal. Confirm a hook record
   lands in `~/.cmuxterm/claude-hook-sessions.json` keyed by the
   panel's UUID.
3. Quit cmux while the session is alive.
4. Relaunch cmux. The session restores: a new terminal panel opens and
   `claude --resume <id> --dangerously-skip-permissions` is fed to its
   PTY.
5. Run `ps -axo command | grep claude`. The argv shows
   `/opt/homebrew/bin/claude --resume <id> --dangerously-skip-permissions`
   — note the **absolute path**, no `--session-id`, no `--settings`.
6. Watch `~/.cmuxterm/claude-hook-sessions.json`. The restored session
   does not appear in the store; the previous record stays stale until
   the user takes a turn (whose Stop hook fires through some unrelated
   path).

The user-visible failure: any UI surface that consults the hook store
for "is there an active Claude session in this panel?" reports `nil`,
even though the panel obviously has a live Claude.

## Existing architecture (already correct in spirit)

cmux already has a sophisticated dual-layer mechanism for routing
`claude` invocations through the bundled wrapper:

| Layer | Code path | What it does |
|---|---|---|
| 1. Shell function | `Resources/shell-integration/cmux-zsh-integration.zsh:161–179` | `_cmux_install_cli_wrapper claude _CMUX_CLAUDE_WRAPPER` defines a zsh function `claude() { "$_CMUX_CLAUDE_WRAPPER" "$@"; }`. Functions resolve before PATH lookup, so user-typed `claude` always hits the bundled wrapper. |
| 2. PATH guard | `Resources/shell-integration/cmux-zsh-integration.zsh:1306–1319` | `_cmux_fix_path` is a one-shot precmd hook that re-prepends `<bundle>/Contents/Resources/bin` to PATH after the user's `.zprofile`/`.zshrc` have run, defeating tools like `brew shellenv` that re-prepend `/opt/homebrew/bin`. |
| 3. ZDOTDIR override | `Sources/GhosttyTerminalView.swift:5726–5784` | Sets `ZDOTDIR=<bundle>/Resources/shell-integration` for spawned zsh shells, so layer 1 and layer 2 actually load. |

Both layers correctly handle the case where the user types `claude` in
a fresh cmux terminal. The Diagnostic block in the original report
confirmed:

```
$ type claude
claude is a shell function from '<bundle>/.../cmux-zsh-integration.zsh'
```

So **fresh sessions work correctly**. The hooks fire, records are
written, the wrapper injects `--session-id` / `--settings`.

## Why restoration fails

Session restoration goes through a different code path:
`Sources/RestorableAgentSession.swift:215–222`:

```swift
case .claude:
    return resumeWithOption(
        kind: "claude",
        launchCommand: launchCommand,
        fallbackExecutable: "claude",
        option: "--resume",
        sessionId: sessionId
    )
```

`resumeWithOption` calls `commandParts(launchCommand:, fallbackExecutable:)`
which (lines 521–531) returns the executable as:

```swift
let executable = normalized(launchCommand?.executablePath)
    ?? arguments.first
    ?? fallbackExecutable
```

`launchCommand?.executablePath` was captured at SessionStart hook time
and is the **resolved absolute path** of whichever `claude` the user
actually ran — almost always `/opt/homebrew/bin/claude` on macOS with
Homebrew.

The resume command is then assembled via `shellCommand` (lines 79–103)
into a string like:

```
/usr/bin/env CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1 ... \
  /bin/zsh -lc 'cd /Users/.../project && \
    /opt/homebrew/bin/claude --resume <id> --dangerously-skip-permissions'
```

This string is fed to the panel's PTY as `initialInput`. The shell
parses it. **An absolute path bypasses both the shell function and any
PATH manipulation** — `/opt/homebrew/bin/claude` is invoked directly,
never going through `<bundle>/Contents/Resources/bin/claude`.

Result: the wrapper script never runs, `--session-id` and `--settings`
are never injected, and the hook chain that depends on those flags
silently no-ops.

## The fix

In `Sources/RestorableAgentSession.swift`, modify the `case .claude:`
branch of `resumeArguments` to discard the captured executable path
and re-substitute bare `claude` so the shell function resolves at
exec time:

```swift
case .claude:
    let stripped = launchCommand.map { lc -> AgentLaunchCommandSnapshot in
        var newArgs = lc.arguments
        if !newArgs.isEmpty {
            newArgs[0] = "claude"
        }
        return AgentLaunchCommandSnapshot(
            launcher: lc.launcher,
            executablePath: nil,
            arguments: newArgs,
            workingDirectory: lc.workingDirectory,
            environment: lc.environment,
            capturedAt: lc.capturedAt,
            source: lc.source
        )
    }
    return resumeWithOption(
        kind: "claude",
        launchCommand: stripped,
        fallbackExecutable: "claude",
        option: "--resume",
        sessionId: sessionId
    )
```

Why this works:

- `executablePath: nil` and `arguments[0] = "claude"` together force
  `commandParts` to return `executable = "claude"` (bare).
- The reconstructed shell command becomes
  `... /bin/zsh -lc 'cd <cwd> && claude --resume <id> --dangerously-skip-permissions'`.
- zsh reads `claude`, resolves it against the cmux-installed shell
  function, executes the bundled wrapper, which checks the cmux socket
  and injects `--session-id` / `--settings` before exec-ing the real
  `claude`.
- Hooks fire. Hook records get written. Inspector attaches. Other
  consumers see a fresh record.
- Nothing about claude's argv preservation logic changes; `tail` still
  gets the user's preserved flags (`--dangerously-skip-permissions`,
  `--config <path>`, etc.) via the existing
  `AgentLaunchSanitizer.preservedArguments` chain inside `resumeWithOption`.

## Risk and edge cases

- **No regression for non-Claude agents.** The change is gated on
  `case .claude:` in the kind switch.
- **Custom claude installs at non-standard paths.** Users who install
  claude at e.g. `/opt/anthropic/bin/claude` and configured cmux's
  "Custom claude binary path" Setting will still find their binary —
  the cmux wrapper consults `CMUX_CUSTOM_CLAUDE_PATH`. Users WITHOUT
  the wrapper (Claude Code Integration disabled) will still find
  claude via PATH. The only loss is for the unusual configuration of
  "wrapper disabled AND user's PATH doesn't include claude's location",
  which is functionally broken anyway.
- **Restore from old hook records.** Records written by previous cmux
  versions retain `executablePath: "/opt/homebrew/bin/claude"`. After
  this fix, those records still resolve correctly because we replay
  them through `claude` regardless of stored executable path.
- **`cmux fork` flow.** The fork command uses `forkArguments`, not
  `resumeArguments`, and is out of scope. (A symmetric fix may be
  desirable; tracked separately.)

## Test plan for a maintainer

1. Apply the patch.
2. Open cmux. Start `claude` in a fresh terminal. Confirm
   `~/.cmuxterm/claude-hook-sessions.json` records the session.
3. `ps -axo command | grep claude` — should show the bundled wrapper
   as ancestor and `--session-id` / `--settings` injected at the real
   claude invocation.
4. Quit cmux. Relaunch.
5. The restored panel runs `claude --resume <id>`. Run
   `ps -axo command | grep claude` — argv should NO LONGER contain
   `/opt/homebrew/bin/claude` as the first executable token. It should
   show the wrapper having run, with `--session-id` / `--settings`
   present in the final claude argv.
6. Tail `~/.cmuxterm/claude-hook-sessions.json`. Within a few seconds
   of restoration, a fresh hook record for the restored panel should
   appear.
7. Repeat with `cmux hooks setup`-installed agents that follow the
   same pattern (codex, grok if `--resume`-style) — confirm no
   regression.
8. Run unit tests:
   ```bash
   xcodebuild -scheme cmux-unit -destination 'platform=macOS' \
     -only-testing:cmuxTests/RestorableAgentSessionTests \
     test
   ```
   (Add a test case if the existing suite doesn't cover the
   `executablePath` substitution.)

## Why the existing layers (function + PATH guard) didn't cover this

Both layers operate at the **shell** level — they intercept user-typed
or shell-parsed `claude` invocations. Restoration's resume command,
however, embeds the absolute path directly inside a `zsh -lc 'cmd'`
payload that's fed to the panel's PTY. The shell parses that payload,
sees an absolute path token, and exec's it directly, never consulting
the function table or PATH. The wrapper layers are bypassed by design
in this case — the bug is that restoration was capturing and replaying
the resolved absolute path instead of the abstract command name.

## Related

- `docs/agent-hooks.md` — describes the wrapper-injected settings model
  for Claude Code.
- `Resources/bin/claude` — the wrapper script itself, contains a
  `cmux_socket_available` check that adds another silent-passthrough
  failure mode (timeout-based; not directly relevant to this PR but
  worth following up).
