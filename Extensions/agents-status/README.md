# Agents Status

Shows live coding-agent session state (Working / Waiting / Idle / Error) as
a 5×5 pixel animation in the island. Tracks **multiple concurrent sessions**
across agents and terminals.

Currently bridges:

- **Claude Code** — full event coverage via hooks (Working / Waiting / Idle / Error)
- **Codex CLI** — official hooks via `~/.codex/config.toml` + `~/.codex/hooks.json`
  (turn-aware Working / Idle plus transient Error when an active turn exits
  unexpectedly)

## How it works

Agent hooks are shell commands, but SuperIsland extensions run in a sandbox
with no filesystem or IPC. A tiny local HTTP server bridges them:

```
Claude Code / Codex hooks  --curl POST-->  127.0.0.1:7823  <--GET poll--  extension
```

- Hooks POST enriched events (session_id, cwd, title, terminal) on every agent event.
- The bridge tracks state per `(agent, session_id)` so multiple concurrent
  sessions show up as a list in the expanded/full views.
- Click a session row in the expanded or full-expanded view to jump back to
  that terminal session. In Warp, the bridge resolves the current tab by its
  custom tab title and sends `Cmd+<index>` to jump directly to it; Terminal.app
  still selects the matching tab by TTY; unsupported terminals fall back to
  simply bringing the app to the front.
- Sessions silent for longer than the configured TTL (10–60 min, default 30)
  drop off the list.
- Claude `Working` sessions auto-decay to `Idle` after 30 s of silence so a
  crashed hook can't leave a session stuck. Codex keeps `Working` for the
  active turn until `Stop` arrives, the CLI exits, or the transcript records
  an interrupted `<turn_aborted>` marker.

## Install

The extension is bundled with Super Island — no scripts to run. Just enable it
in **Super Island → Settings → Extensions**. The bridge server (`server.py`)
starts automatically when the extension activates and stops when it's disabled
or the app quits.

Requirement: Python 3 must be available on PATH (`/opt/homebrew/bin/python3`,
`/usr/local/bin/python3`, or `/usr/bin/python3`). On macOS, installing the
Command Line Tools via `xcode-select --install` is enough.

Verify the bridge is running:

```bash
curl http://127.0.0.1:7823/health
# {"ok":true,"port":7823,"paused":false}
```

### Enable the agents you want

In the extension settings, toggle:

- **Claude Code** — merges hooks into `~/.claude/settings.json`
- **Codex CLI** — enables `features.codex_hooks = true` in
  `~/.codex/config.toml` and installs command hooks in `~/.codex/hooks.json`

Both are idempotent and keep backups (`.agents-status.bak`). Un-toggling removes
only the entries this extension added.

### 4. Test

```bash
curl -s -X POST http://127.0.0.1:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"Working","agent":"Claude","session_id":"demo","title":"testing","cwd":"/tmp","terminal":"iTerm"}'
curl http://127.0.0.1:7823/state
```

## State mapping

| Claude Code hook        | State        |
| ----------------------- | ------------ |
| `SessionStart`          | Idle         |
| `UserPromptSubmit`      | Working      |
| `PreToolUse`            | Working      |
| `PostToolUse`           | Working      |
| `PostToolUseFailure` (`is_interrupt=true`) | Idle |
| `Notification`          | Waiting      |
| `Stop`                  | Idle         |
| `SessionEnd`            | removes session |

| Codex hook             | State        |
| ---------------------- | ------------ |
| `SessionStart`         | Idle         |
| `UserPromptSubmit`     | Working      |
| `PreToolUse`           | Working      |
| `PostToolUse`          | Working      |
| `Stop`                 | Idle         |

For Codex, Bash command exit codes are treated as normal tool outcomes, not as
agent errors. `Error` is only surfaced when an active Codex turn disappears
unexpectedly before `Stop` arrives. There is no dedicated interrupt hook today,
so ESC interrupts fall back to the transcript's `<turn_aborted>` marker.

`PostToolUse` is currently limited by Codex itself to Bash payloads, per the
official hooks docs. Other tool types are not intercepted there yet.

## Config

Extension settings:

- **Claude Code / Codex CLI toggles** — reconciles hooks on change.

Active sessions stay visible until the owning Claude/Codex process exits or
the agent emits an explicit session-end event.

### Warp tab naming

For stable Warp switching, give each agent tab a distinct custom title such as
`repo-cc` and `repo-cx`. The island shows that tab title directly, and clicking
the row switches to the matching Warp tab by its current on-screen index.

Server env vars (injected automatically by Super Island when the extension
activates — the host owns the process, so no plist or launchd involvement):

- `AGENTS_STATUS_PORT` — default `7823`
- `AGENTS_STATUS_WORKING_TIMEOUT` — seconds before stale `Working` decays to `Idle` (default `30`)
- `AGENTS_STATUS_ERROR_DISPLAY_SECONDS` — how long an unexpected Codex exit stays visible as `Error` (default `45`)
- `AGENTS_STATUS_CC_HOOK_SCRIPT` — path to the Claude Code hook script (`cc-event-hook.sh`)
- `AGENTS_STATUS_CODEX_HOOK_SCRIPT` — path to the Codex hook bridge script

## Upgrading from 1.2.x / earlier

The bridge is now managed by Super Island itself — old versions relied on a
`launchd` user agent installed via `server/install.sh`. On first launch of the
new extension, any `com.superisland.agents-status` or `com.superisland.cc-status`
LaunchAgent left over from previous installs is booted out and its plist
removed automatically, so there's nothing to clean up by hand.

After upgrading, toggle Claude Code and/or Codex off and back on in settings
to make sure the hook entries in `~/.claude/settings.json` and
`~/.codex/hooks.json` point at the bundled hook scripts.

## Troubleshooting

- **Island shows `offline`**: the bridge failed to start. Open
  Super Island → Settings → Extensions → Agents Status → Logs to see the
  Python process output, or verify `python3` is installed (see Install).
- **No sessions appear**: make sure hooks are installed in the settings file
  your agent actually reads (user-level vs project-level for Claude Code,
  `~/.codex/config.toml` and `~/.codex/hooks.json` for Codex).
- **Clicking a session doesn't switch tabs in Warp**: macOS may block UI
  scripting until you grant Automation / Accessibility access to the bridge's
  `osascript` call. Re-try once after granting permission.
- **Codex shows `Error` too often**: update to the latest `agents-status`.
  Recent versions only surface `Error` for unexpected active-turn exits, not
  ordinary Bash command failures.
