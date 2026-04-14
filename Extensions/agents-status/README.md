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
  active turn until `Stop` arrives or the CLI exits.

## Install

### 1. Install the extension

```bash
./scripts/apply-extensions.sh agents-status
```

Then enable it in SuperIsland → Settings → Extensions.

### 2. Start the bridge server

```bash
./agents-status/server/install.sh
```

This installs a `launchd` user agent that runs `server.py` at login and
restarts it on crash. Logs: `~/Library/Logs/SuperIsland/agents-status.*.log`.

Verify:

```bash
curl http://127.0.0.1:7823/health
# {"ok":true,"port":7823,"paused":false}
```

### 3. Enable the agents you want

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
| `PostToolUse` (ok)      | Working      |
| `PostToolUse` (error)   | Error        |
| `Notification`          | Waiting      |
| `Stop` / `SubagentStop` | Idle         |

| Codex hook             | State        |
| ---------------------- | ------------ |
| `SessionStart`         | Idle         |
| `UserPromptSubmit`     | Working      |
| `PreToolUse`           | Working      |
| `PostToolUse`          | Working      |
| `Stop`                 | Idle         |

For Codex, Bash command exit codes are treated as normal tool outcomes, not as
agent errors. `Error` is only surfaced when an active Codex turn disappears
unexpectedly before `Stop` arrives.

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

Server env vars (set via the `launchd` plist — edit `install.sh` and reinstall
if you need to change them):

- `AGENTS_STATUS_PORT` — default `7823`
- `AGENTS_STATUS_WORKING_TIMEOUT` — seconds before stale `Working` decays to `Idle` (default `30`)
- `AGENTS_STATUS_ERROR_DISPLAY_SECONDS` — how long an unexpected Codex exit stays visible as `Error` (default `45`)
- `AGENTS_STATUS_CC_HOOK_SCRIPT` — path to the Claude Code hook script (`cc-event-hook.sh`)
- `AGENTS_STATUS_CODEX_HOOK_SCRIPT` — path to the Codex hook bridge script

## Upgrading from 1.2.x

1.3.0 renamed the hook script from `cc-posttool-hook.sh` to `cc-event-hook.sh`,
added Codex support, and changed the `/event` payload shape. Re-run
`./agents-status/server/install.sh` after updating, then toggle Claude Code
off and back on in settings to rewrite the hook entries.

Recent versions also renamed the bridge's generic identifiers from `cc-status`
to `agents-status` while keeping Claude-specific `cc-` names like
`cc-event-hook.sh`.

## Troubleshooting

- **Island shows `offline`**: bridge isn't reachable. Check
  `~/Library/Logs/SuperIsland/agents-status.err.log` and
  `launchctl list | grep agents-status`.
- **No sessions appear**: make sure hooks are installed in the settings file
  your agent actually reads (user-level vs project-level for Claude Code,
  `~/.codex/config.toml` and `~/.codex/hooks.json` for Codex).
- **Clicking a session doesn't switch tabs in Warp**: macOS may block UI
  scripting until you grant Automation / Accessibility access to the bridge's
  `osascript` call. Re-try once after granting permission.
- **Codex shows `Error` too often**: update to the latest `agents-status`.
  Recent versions only surface `Error` for unexpected active-turn exits, not
  ordinary Bash command failures.
