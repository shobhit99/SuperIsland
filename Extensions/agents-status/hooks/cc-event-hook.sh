#!/bin/bash
# Claude Code unified hook — reads the hook JSON on stdin, enriches it with
# session metadata (title from transcript, terminal from $TERM_PROGRAM), and
# POSTs it to the bridge.
# Usage: cc-event-hook.sh <state>
#   state = Working | Waiting | Idle | Error | Auto
#   Auto  = PostToolUse — infer Working/Error from tool_response
# Always exits 0 so Claude Code is never blocked.

set -u
STATE="${1:-Working}"
PORT="${AGENTS_STATUS_PORT:-7823}"

find_agent_pid() {
  local pid=$PPID
  local max=6
  while [ "$max" -gt 0 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    local name
    name=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$name" in
      *claude*|*Claude*) echo "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    max=$((max - 1))
  done
  return 1
}
AGENT_PID="$(find_agent_pid 2>/dev/null || true)"

# Drain stdin first — the heredoc below replaces stdin with the Python
# source code, so we can't let json.load(sys.stdin) compete with it.
HOOK_JSON=$(cat)

payload=$(
  STATE="$STATE" \
  HOOK_JSON="$HOOK_JSON" \
  TERM_PROGRAM="${TERM_PROGRAM:-}" \
  AGENT_PID="${AGENT_PID:-}" \
  /usr/bin/python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.loads(os.environ.get("HOOK_JSON") or "{}")
except Exception:
    d = {}

state = os.environ.get("STATE", "Working")
if state == "Auto":
    # PostToolUse: tool-level errors (Bash exit codes, is_error, etc.) are
    # not agent errors. Keep the session Working; only CLI crashes or lost
    # processes flip to Error (detected server-side via dead PID).
    state = "Working"
elif state == "ToolFail":
    # PostToolUseFailure: fires when a tool call fails. `is_interrupt` is
    # true when the failure was an ESC interrupt by the user — the only
    # reliable signal for "user hit ESC", since Stop isn't dispatched in
    # that case. Treat it as turn-end; regular tool failures keep Working.
    if d.get("is_interrupt") is True:
        state = "Idle"
    else:
        state = "Working"
elif state == "Waiting":
    # Claude's Notification hook fires for two very different cases:
    #   1. Permission prompt: "Claude needs your permission to use <Tool>"
    #   2. 60s idle reminder: "Claude is waiting for your input"
    # Only (1) is a real Waiting state; (2) means the session is Idle.
    msg = (d.get("message") or "")
    if "permission" in msg.lower():
        state = "Waiting"
    else:
        state = "Idle"

session_id = d.get("session_id") or "default"
cwd = d.get("cwd") or ""
transcript = d.get("transcript_path") or ""

# Title: newest user-authored message in the transcript (plain-string content).
# Array-form user entries are usually tool_result injections, skip those.
title = ""
if transcript and os.path.exists(transcript):
    try:
        with open(transcript, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get("type") != "user":
                continue
            msg = m.get("message") or {}
            content = msg.get("content")
            if isinstance(content, str) and content.strip():
                title = content.strip()
                break
    except Exception:
        pass

# Fallback: UserPromptSubmit carries the prompt directly.
if not title and d.get("hook_event_name") == "UserPromptSubmit":
    p = d.get("prompt")
    if isinstance(p, str) and p.strip():
        title = p.strip()

title = title[:120]

term_map = {
    "iTerm.app": "iTerm",
    "Apple_Terminal": "Terminal",
    "vscode": "VS Code",
    "WarpTerminal": "Warp",
    "ghostty": "Ghostty",
    "Hyper": "Hyper",
    "WezTerm": "WezTerm",
    "kitty": "kitty",
    "tabby": "Tabby",
    "alacritty": "Alacritty",
}
raw_term = os.environ.get("TERM_PROGRAM") or ""
term = term_map.get(raw_term, raw_term)

try:
    pid = int(os.environ.get("AGENT_PID") or 0) or None
except Exception:
    pid = None

sys.stdout.write(json.dumps({
    "state": state,
    "agent": "Claude",
    "session_id": session_id,
    "cwd": cwd,
    "title": title,
    "terminal": term,
    "pid": pid,
    "transcript_path": transcript,
}))
PY
)

if [ -z "${payload:-}" ]; then
  payload="{\"state\":\"${STATE}\",\"agent\":\"Claude\"}"
fi

# SessionEnd: Claude Code is quitting, so run curl synchronously — a
# backgrounded child would get killed with the parent before it lands.
if [ "$STATE" = "Ended" ]; then
  curl -s -m 2 -X POST "http://127.0.0.1:${PORT}/event" \
    -H 'Content-Type: application/json' \
    --data-raw "$payload" >/dev/null 2>&1
else
  curl -s -m 1 -X POST "http://127.0.0.1:${PORT}/event" \
    -H 'Content-Type: application/json' \
    --data-raw "$payload" >/dev/null 2>&1 &
fi

exit 0
