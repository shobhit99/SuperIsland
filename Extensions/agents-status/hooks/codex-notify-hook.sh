#!/bin/bash
# Codex CLI hook command — wired via ~/.codex/hooks.json and fed one hook JSON
# object on stdin. It maps Codex lifecycle events to island states and POSTs
# the enriched state to the local bridge.

set -u
PORT="${AGENTS_STATUS_PORT:-7823}"
HOOK_JSON=$(cat)

# Walk up the process tree to find the long-lived Codex CLI ancestor. Codex has
# no session-end hook, so the server can prune stale sessions faster by probing
# this PID with kill -0.
find_agent_pid() {
  local pid=$PPID
  local max=6
  while [ "$max" -gt 0 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    local name
    name=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$name" in
      *codex*|*Codex*) echo "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    max=$((max - 1))
  done
  return 1
}
AGENT_PID="$(find_agent_pid 2>/dev/null || true)"

payload=$(
  HOOK_JSON="$HOOK_JSON" \
  TERM_PROGRAM="${TERM_PROGRAM:-}" \
  AGENT_PID="${AGENT_PID:-}" \
  /usr/bin/python3 - <<'PY' 2>/dev/null
import json, os, re, sys


def parse_exit_code(tool_response):
    value = tool_response
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return 0
        try:
            value = json.loads(stripped)
        except Exception:
            m = re.search(r"Exit code:\s*(-?\d+)", stripped)
            if m:
                try:
                    return int(m.group(1))
                except Exception:
                    return None
            return None

    if isinstance(value, dict):
        metadata = value.get("metadata")
        if isinstance(metadata, dict):
            exit_code = metadata.get("exit_code")
            if isinstance(exit_code, int):
                return exit_code
            if isinstance(exit_code, float):
                return int(exit_code)
        exit_code = value.get("exit_code")
        if isinstance(exit_code, int):
            return exit_code
        if isinstance(exit_code, float):
            return int(exit_code)

    return None


try:
    d = json.loads(os.environ.get("HOOK_JSON") or "{}")
except Exception:
    d = {}

event = d.get("hook_event_name") or ""
if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
    state = "Working"
else:
    state = "Idle"

prompt = d.get("prompt")
title = prompt.strip()[:120] if isinstance(prompt, str) and prompt.strip() else ""

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

last_assistant_message = d.get("last_assistant_message")
if not isinstance(last_assistant_message, str):
    last_assistant_message = None

sys.stdout.write(json.dumps({
    "state": state,
    "agent": "Codex",
    "event": event,
    "session_id": d.get("session_id") or "default",
    "cwd": d.get("cwd") or "",
    "title": title,
    "terminal": term,
    "pid": pid,
    "turn_id": d.get("turn_id") or "",
    "last_assistant_message": last_assistant_message,
    "tool_name": d.get("tool_name") or "",
    "tool_command": ((d.get("tool_input") or {}).get("command") if isinstance(d.get("tool_input"), dict) else "") or "",
    "tool_exit_code": parse_exit_code(d.get("tool_response")),
    "stop_hook_active": bool(d.get("stop_hook_active")),
}))
PY
)

if [ -z "${payload:-}" ]; then
  payload='{"state":"Idle","agent":"Codex"}'
fi

curl -s -m 1 -X POST "http://127.0.0.1:${PORT}/event" \
  -H 'Content-Type: application/json' \
  --data-raw "$payload" >/dev/null 2>&1 &

exit 0
