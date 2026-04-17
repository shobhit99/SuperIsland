#!/usr/bin/env python3
"""
Agents Status bridge for SuperIsland.

Tracks state per (agent, session_id) so the extension can render a list of
active coding-agent sessions. Currently bridges Claude Code and Codex CLI
through their official hook mechanisms.

Raw-socket HTTP/1.1 server. Routes:

  POST /event            enrich/update a session — body: {state, agent, session_id,
                         cwd, title, terminal}
  POST /focus            focus a tracked session's terminal/tab — body: {agent, session_id}
  GET  /state            {sessions: [...], state, updated_at}   (state/updated_at
                         reflect the "worst" live session for legacy callers)
  GET  /health           liveness
  POST /control/pause    stop accepting /event updates
  POST /control/resume   resume accepting /event updates
  GET  /control/status   {paused: bool}
  POST /hooks/install    ?agent=claude|codex — merge hooks into the agent's config
  POST /hooks/uninstall  ?agent=claude|codex — remove our hooks
  GET  /hooks/status     ?agent=claude|codex — {installed, events}

Working states auto-decay to Idle after WORKING_TIMEOUT seconds of silence.
Codex turns stay Working across "thinking" gaps until Stop arrives or the
tracked CLI process disappears. Sessions with a tracked agent PID stay visible
until that process exits or an explicit session-end event removes them. TTL
pruning remains only as a fallback for legacy sessions that never reported a
PID (caller can override via ?ttl=<seconds>).
"""

import json
import os
import pathlib
import re
import shlex
import shutil
import sqlite3
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

PORT = int(os.environ.get("AGENTS_STATUS_PORT") or os.environ.get("CC_STATUS_PORT", "7823"))
WORKING_TIMEOUT = float(
    os.environ.get("AGENTS_STATUS_WORKING_TIMEOUT") or
    os.environ.get("CC_STATUS_WORKING_TIMEOUT", "30")
)
# How long a Claude session can sit "Working" with zero hook events AND a
# stale transcript before we assume the Stop hook was missed (commonly: ESC
# interrupt) and auto-flip to Idle. Generous enough that long-running tool
# calls don't false-trip.
CLAUDE_IDLE_GRACE = float(os.environ.get("AGENTS_STATUS_CLAUDE_IDLE_GRACE", "180"))
ERROR_DISPLAY_SECONDS = float(os.environ.get("AGENTS_STATUS_ERROR_DISPLAY_SECONDS", "45"))
SESSION_TTL_DEFAULT = float(os.environ.get("AGENTS_STATUS_SESSION_TTL", "1800"))  # 30 min
CODEX_SCAN_INTERVAL = float(os.environ.get("AGENTS_STATUS_CODEX_SCAN_INTERVAL", "1.0"))
CLAUDE_SCAN_INTERVAL = float(os.environ.get("AGENTS_STATUS_CLAUDE_SCAN_INTERVAL", "1.0"))
# When an explicit session-end event (or a pid-alive drop) closes a session,
# remember its PID briefly so the next startup scan — which may still be
# using a stale `ps` snapshot — doesn't resurrect a synthetic placeholder
# that immediately gets flagged Error by _mark_unexpected_*_exits.
RECENTLY_ENDED_PID_TTL = float(os.environ.get("AGENTS_STATUS_RECENTLY_ENDED_TTL", "8"))
INSTALLED_EXT_ROOT = (
    pathlib.Path.home() /
    "Library" / "Application Support" / "SuperIsland" / "Extensions" / "agents-status"
)
DEFAULT_CC_HOOK_SCRIPT = str(INSTALLED_EXT_ROOT / "hooks" / "cc-event-hook.sh")
DEFAULT_CODEX_HOOK_SCRIPT = str(INSTALLED_EXT_ROOT / "hooks" / "codex-notify-hook.sh")
CC_HOOK_SCRIPT = (
    os.environ.get("AGENTS_STATUS_CC_HOOK_SCRIPT") or
    os.environ.get("CC_STATUS_HOOK_SCRIPT") or
    DEFAULT_CC_HOOK_SCRIPT
)
CODEX_HOOK_SCRIPT = (
    os.environ.get("AGENTS_STATUS_CODEX_HOOK_SCRIPT") or
    os.environ.get("CC_STATUS_CODEX_HOOK_SCRIPT") or
    DEFAULT_CODEX_HOOK_SCRIPT
)
VALID_STATES = ("Working", "Waiting", "Idle", "Error")
BACKUP_SUFFIX = ".agents-status.bak"

CC_SETTINGS_PATH = pathlib.Path.home() / ".claude" / "settings.json"
CC_HOOK_MARKER = "# cc-status-hook"

CODEX_CONFIG_PATH = pathlib.Path.home() / ".codex" / "config.toml"
CODEX_HOOKS_PATH = pathlib.Path.home() / ".codex" / "hooks.json"
CODEX_MARKER = "# agents-status-managed"
CODEX_HOOK_MARKER = "# agents-status-hook"
CODEX_FEATURE_MARKER = "# agents-status-managed-codex-hooks"
CODEX_FEATURE_RESTORE_PREFIX = "# agents-status-restore-codex-hooks "
CODEX_EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop")
TERMINAL_APP_NAMES = {
    "Warp": "Warp",
    "Terminal": "Terminal",
    "VS Code": "Visual Studio Code",
    "iTerm": "iTerm",
    "Ghostty": "Ghostty",
    "WezTerm": "WezTerm",
    "Tabby": "Tabby",
    "Hyper": "Hyper",
    "kitty": "kitty",
    "Alacritty": "Alacritty",
}
WARP_SQLITE_PATH = (
    pathlib.Path.home() /
    "Library" / "Group Containers" / "2BBY89MBSN.dev.warp" /
    "Library" / "Application Support" / "dev.warp.Warp-Stable" / "warp.sqlite"
)
CODEX_NONINTERACTIVE_COMMANDS = frozenset((
    "app",
    "app-server",
    "apply",
    "cloud",
    "completion",
    "debug",
    "exec",
    "exec-server",
    "features",
    "help",
    "login",
    "logout",
    "mcp",
    "mcp-server",
    "review",
    "sandbox",
))
CLAUDE_NONINTERACTIVE_COMMANDS = frozenset((
    "config",
    "mcp",
    "doctor",
    "update",
    "install",
    "migrate-installer",
    "logout",
    "setup-token",
    "help",
))
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
WARP_TAB_KEY_CODES = {
    1: 18,
    2: 19,
    3: 20,
    4: 21,
    5: 23,
    6: 22,
    7: 26,
    8: 28,
    9: 25,
}

# sessions[(agent, session_id)] = {
#   agent, session_id, state, title, cwd, terminal, pid, turn_id,
#   turn_active, turn_started_at, last_event, updated_at, synthetic
# }
_sessions = {}
_paused = False
_lock = threading.Lock()
_codex_scan_lock = threading.Lock()
_last_codex_scan_at = 0.0
_last_codex_scan_results = []
_claude_scan_lock = threading.Lock()
_last_claude_scan_at = 0.0
_last_claude_scan_results = []
# pid -> unix-ts-when-entry-expires. Populated when a session is removed
# explicitly (state=Ended) or pruned for a dead PID; checked by the
# startup-scan sync so stale `ps` results don't resurrect the session.
_recently_ended_pids = {}

# Pending AskUserQuestion permissions. Each entry blocks a PermissionRequest
# hook thread on its `event` until the extension POSTs /permission/resolve
# with the chosen option (or the hook times out).
# permission_id -> {
#   session_id, agent, tool_name, tool_input, questions, created_at,
#   event (threading.Event), decision (dict or None)
# }
_pending_permissions = {}
_pending_permissions_lock = threading.Lock()
PERMISSION_HOOK_TIMEOUT = float(os.environ.get("AGENTS_STATUS_PERMISSION_TIMEOUT", "590"))


# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

def _codex_is_interactive_process(args):
    try:
        argv = shlex.split(args or "")
    except Exception:
        argv = (args or "").split()
    if not argv:
        return False
    exe = os.path.basename((argv[0] or "").strip("\"'"))
    if exe != "codex":
        return False

    flags_with_value = {
        "-C", "--cd",
        "-c", "--config",
        "-m", "--model",
        "-p", "--profile",
        "-s", "--sandbox",
        "-a", "--ask-for-approval",
        "-i", "--image",
        "--add-dir",
        "--disable",
        "--enable",
        "--local-provider",
        "--remote",
        "--remote-auth-token-env",
    }

    i = 1
    while i < len(argv):
        token = argv[i]
        if token == "--":
            break
        if token in ("-h", "--help", "-V", "--version"):
            return False
        if token.startswith("-"):
            if token.startswith("--") and "=" in token:
                token = token.split("=", 1)[0]
            if token in flags_with_value:
                i += 2
                continue
            i += 1
            continue
        return token not in CODEX_NONINTERACTIVE_COMMANDS
    return True


def _cwd_for_pid(pid):
    try:
        res = subprocess.run(
            ["lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
            capture_output=True,
            text=True,
            timeout=0.6,
            check=False,
        )
    except Exception:
        return ""
    for line in (res.stdout or "").splitlines():
        if line.startswith("n"):
            return line[1:].strip()
    return ""


def _ps_row_for_pid(pid):
    try:
        pid = int(pid)
    except Exception:
        return None
    if pid <= 1:
        return None
    try:
        res = subprocess.run(
            ["ps", "-o", "pid=,ppid=,tty=,comm=,args=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=0.6,
            check=False,
        )
    except Exception:
        return None
    raw = (res.stdout or "").strip()
    if not raw:
        return None
    m = re.match(r"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s*(.*)$", raw)
    if not m:
        return None
    pid_text, ppid_text, tty, comm, args = m.groups()
    return {
        "pid": int(pid_text),
        "ppid": int(ppid_text),
        "tty": "" if tty in ("?", "??") else tty,
        "comm": os.path.basename(comm),
        "args": args or "",
    }


def _infer_terminal_from_row(row):
    if not row:
        return ""
    hay = f"{row.get('comm') or ''} {row.get('args') or ''}".lower()
    if "/applications/warp.app/" in hay or "dev.warp" in hay or " terminal-server " in f" {hay} ":
        return "Warp"
    if "/system/applications/utilities/terminal.app/" in hay or row.get("comm") == "Terminal":
        return "Terminal"
    if "/applications/iterm.app/" in hay or "iterm" in hay:
        return "iTerm"
    if "/applications/visual studio code.app/" in hay or row.get("comm") == "Code":
        return "VS Code"
    if "ghostty" in hay:
        return "Ghostty"
    if "wezterm" in hay:
        return "WezTerm"
    if "tabby" in hay:
        return "Tabby"
    if "hyper" in hay:
        return "Hyper"
    if "kitty" in hay:
        return "kitty"
    if "alacritty" in hay:
        return "Alacritty"
    return ""


def _infer_terminal_from_pid(pid, max_depth=8):
    seen = set()
    current = pid
    depth = 0
    while depth < max_depth:
        row = _ps_row_for_pid(current)
        if not row:
            return ""
        found = _infer_terminal_from_row(row)
        if found:
            return found
        current = row.get("ppid")
        if not current or current <= 1 or current in seen:
            return ""
        seen.add(current)
        depth += 1
    return ""


def _scan_codex_startup_candidates(now):
    global _last_codex_scan_at, _last_codex_scan_results
    with _codex_scan_lock:
        if (now - _last_codex_scan_at) < CODEX_SCAN_INTERVAL:
            return [dict(item) for item in _last_codex_scan_results]
        try:
            res = subprocess.run(
                ["ps", "-axo", "pid=,tty=,comm=,args="],
                capture_output=True,
                text=True,
                timeout=0.8,
                check=False,
            )
        except Exception:
            _last_codex_scan_at = now
            _last_codex_scan_results = []
            return []

        found = []
        for raw in (res.stdout or "").splitlines():
            m = re.match(r"^\s*(\d+)\s+(\S+)\s+(\S+)\s*(.*)$", raw)
            if not m:
                continue
            pid_text, tty, comm, args = m.groups()
            if tty in ("?", "??"):
                continue
            if os.path.basename(comm) != "codex":
                continue
            if not _codex_is_interactive_process(args):
                continue
            pid = int(pid_text)
            found.append({
                "agent": "Codex",
                "session_id": f"pid:{pid}",
                "state": "Idle",
                "title": "",
                "cwd": _cwd_for_pid(pid),
                "terminal": _infer_terminal_from_pid(pid),
                "pid": pid,
                "synthetic": True,
            })

        _last_codex_scan_at = now
        _last_codex_scan_results = [dict(item) for item in found]
        return [dict(item) for item in found]


def _sync_codex_startup_sessions(now, candidates):
    real_pids = set()
    for s in _sessions.values():
        if s.get("agent") == "Codex" and not s.get("synthetic") and s.get("pid"):
            real_pids.add(s.get("pid"))

    for key, s in list(_sessions.items()):
        if s.get("agent") != "Codex" or not s.get("synthetic"):
            continue
        if s.get("pid") in real_pids:
            del _sessions[key]

    for item in candidates:
        pid = item.get("pid")
        if not pid or pid in real_pids:
            continue
        if _pid_recently_ended(pid, now) or not _pid_alive(pid):
            continue
        key = ("Codex", item["session_id"])
        existing = _sessions.get(key) or {}
        _sessions[key] = {
            "agent": "Codex",
            "session_id": item["session_id"],
            "state": "Idle",
            "title": (existing.get("title") or item.get("title") or "")[:200],
            "cwd": item.get("cwd") or existing.get("cwd") or "",
            "terminal": existing.get("terminal") or item.get("terminal") or "",
            "pid": pid,
            "turn_id": existing.get("turn_id"),
            "turn_active": existing.get("turn_active", False),
            "turn_started_at": existing.get("turn_started_at"),
            "last_event": existing.get("last_event"),
            "last_assistant_message": existing.get("last_assistant_message"),
            "error_expires_at": existing.get("error_expires_at"),
            "updated_at": now,
            "synthetic": True,
        }


def _claude_is_interactive_process(args):
    try:
        argv = shlex.split(args or "")
    except Exception:
        argv = (args or "").split()
    if not argv:
        return False
    exe = os.path.basename((argv[0] or "").strip("\"'"))
    if exe != "claude":
        return False

    flags_with_value = {
        "--model", "--fallback-model",
        "--permission-mode",
        "--permission-prompt-tool",
        "--system-prompt", "--append-system-prompt",
        "--mcp-config",
        "--agents",
        "--add-dir",
        "--allowedTools", "--disallowedTools",
        "--session-id",
        "--resume", "-r",
        "--setting-sources",
    }

    i = 1
    while i < len(argv):
        token = argv[i]
        if token == "--":
            break
        if token in ("-h", "--help", "-v", "--version"):
            return False
        if token in ("-p", "--print"):
            return False  # one-shot non-interactive mode
        if token.startswith("-"):
            if token.startswith("--") and "=" in token:
                token = token.split("=", 1)[0]
            if token in flags_with_value:
                i += 2
                continue
            i += 1
            continue
        # First positional: either a subcommand (non-interactive) or an
        # initial prompt string (interactive REPL with that seed prompt).
        return token not in CLAUDE_NONINTERACTIVE_COMMANDS
    return True


def _scan_claude_startup_candidates(now):
    global _last_claude_scan_at, _last_claude_scan_results
    with _claude_scan_lock:
        if (now - _last_claude_scan_at) < CLAUDE_SCAN_INTERVAL:
            return [dict(item) for item in _last_claude_scan_results]
        try:
            res = subprocess.run(
                ["ps", "-axo", "pid=,tty=,comm=,args="],
                capture_output=True,
                text=True,
                timeout=0.8,
                check=False,
            )
        except Exception:
            _last_claude_scan_at = now
            _last_claude_scan_results = []
            return []

        found = []
        for raw in (res.stdout or "").splitlines():
            m = re.match(r"^\s*(\d+)\s+(\S+)\s+(\S+)\s*(.*)$", raw)
            if not m:
                continue
            pid_text, tty, comm, args = m.groups()
            if tty in ("?", "??"):
                continue
            if os.path.basename(comm) != "claude":
                continue
            if not _claude_is_interactive_process(args):
                continue
            pid = int(pid_text)
            found.append({
                "agent": "Claude",
                "session_id": f"pid:{pid}",
                "state": "Idle",
                "title": "",
                "cwd": _cwd_for_pid(pid),
                "terminal": _infer_terminal_from_pid(pid),
                "pid": pid,
                "synthetic": True,
            })

        _last_claude_scan_at = now
        _last_claude_scan_results = [dict(item) for item in found]
        return [dict(item) for item in found]


def _sync_claude_startup_sessions(now, candidates):
    real_pids = set()
    for s in _sessions.values():
        if s.get("agent") == "Claude" and not s.get("synthetic") and s.get("pid"):
            real_pids.add(s.get("pid"))

    for key, s in list(_sessions.items()):
        if s.get("agent") != "Claude" or not s.get("synthetic"):
            continue
        if s.get("pid") in real_pids:
            del _sessions[key]

    for item in candidates:
        pid = item.get("pid")
        if not pid or pid in real_pids:
            continue
        if _pid_recently_ended(pid, now) or not _pid_alive(pid):
            continue
        key = ("Claude", item["session_id"])
        existing = _sessions.get(key) or {}
        _sessions[key] = {
            "agent": "Claude",
            "session_id": item["session_id"],
            "state": "Idle",
            "title": (existing.get("title") or item.get("title") or "")[:200],
            "cwd": item.get("cwd") or existing.get("cwd") or "",
            "terminal": existing.get("terminal") or item.get("terminal") or "",
            "pid": pid,
            "turn_id": existing.get("turn_id"),
            "turn_active": existing.get("turn_active", False),
            "turn_started_at": existing.get("turn_started_at"),
            "last_event": existing.get("last_event"),
            "last_assistant_message": existing.get("last_assistant_message"),
            "error_expires_at": existing.get("error_expires_at"),
            "updated_at": now,
            "synthetic": True,
        }


def _tail_text(path, max_bytes=65536):
    if not path:
        return ""
    try:
        size = os.path.getsize(path)
    except OSError:
        return ""
    try:
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()  # drop partial line
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def _claude_transcript_interrupted(transcript_path):
    # Claude Code doesn't fire the Stop hook when the user ESC-interrupts a
    # turn, but it does append a synthetic user entry whose text starts with
    # "[Request interrupted by user" (either "...by user]" for a plain turn
    # or "...by user for tool use]" mid-tool). If that's the newest user
    # entry in the transcript, the turn is done — flip to Idle immediately
    # instead of waiting out CLAUDE_IDLE_GRACE.
    chunk = _tail_text(transcript_path)
    if not chunk:
        return False
    for line in reversed(chunk.splitlines()):
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
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    text = c.get("text") or ""
                    break
        if not text:
            continue
        return text.lstrip().startswith("[Request interrupted by user")
    return False


def _codex_transcript_interrupted(transcript_path, turn_id):
    # Codex persists a model-visible <turn_aborted> marker into the transcript
    # on ESC interrupt. There is no dedicated interrupt hook today, so treat
    # the newest interrupted marker for the active turn as an immediate Idle.
    chunk = _tail_text(transcript_path)
    if not chunk or "<turn_aborted>" not in chunk:
        return False

    idx = chunk.rfind("<turn_aborted>")
    if idx < 0:
        return False
    marker = chunk[idx:]
    if "</turn_aborted>" in marker:
        marker = marker[:marker.find("</turn_aborted>") + len("</turn_aborted>")]
    if "<reason>interrupted</reason>" not in marker:
        return False
    if turn_id:
        return f"<turn_id>{turn_id}</turn_id>" in marker
    return True


def _decay_working(now):
    # Auto-roll Working sessions to Idle after inactivity. Leaves title/cwd intact.
    for key, s in _sessions.items():
        if s["state"] != "Working":
            continue
        if s.get("agent") == "Codex" and s.get("turn_active"):
            transcript = s.get("transcript_path") or ""
            turn_id = s.get("turn_id") or ""
            if _codex_transcript_interrupted(transcript, turn_id):
                s["state"] = "Idle"
                s["turn_active"] = False
                s["turn_started_at"] = None
                continue
            continue
        # Claude can "think" for long stretches between hook events, and
        # long-running tools like `npm install` can go minutes with zero
        # hooks AND zero transcript writes. Treat a session as still Working
        # as long as EITHER the last hook event or the transcript mtime is
        # recent. Only when both have been silent past CLAUDE_IDLE_GRACE do
        # we assume the Stop hook was missed (e.g. ESC interrupt) and flip
        # to Idle. The generous grace keeps long-tool sessions from false-
        # flipping at the cost of slightly slower ESC recovery.
        if s.get("agent") == "Claude":
            pid = s.get("pid")
            if pid and _pid_alive(pid):
                transcript = s.get("transcript_path") or ""
                # Fast path: ESC-interrupt leaves a marker in the transcript,
                # so we can flip to Idle right away without the long grace.
                if _claude_transcript_interrupted(transcript):
                    s["state"] = "Idle"
                    s["turn_active"] = False
                    s["turn_started_at"] = None
                    continue
                last_activity = s["updated_at"]
                if transcript:
                    try:
                        last_activity = max(last_activity, os.path.getmtime(transcript))
                    except OSError:
                        pass
                if (now - last_activity) <= CLAUDE_IDLE_GRACE:
                    continue
                s["state"] = "Idle"
                continue
        if (now - s["updated_at"]) > WORKING_TIMEOUT:
            s["state"] = "Idle"


def _remember_ended_pid(pid, now=None):
    try:
        pid = int(pid)
    except Exception:
        return
    if pid <= 1:
        return
    if now is None:
        now = time.time()
    _recently_ended_pids[pid] = now + RECENTLY_ENDED_PID_TTL


def _pid_recently_ended(pid, now):
    try:
        pid = int(pid)
    except Exception:
        return False
    expires = _recently_ended_pids.get(pid)
    return bool(expires and expires > now)


def _gc_recently_ended(now):
    for pid in [p for p, exp in _recently_ended_pids.items() if exp <= now]:
        _recently_ended_pids.pop(pid, None)


def _pid_alive(pid):
    # Codex has no session-end hook; we prune by probing the long-lived agent
    # PID the hook captured. kill(pid, 0) with signal 0 doesn't actually send
    # anything — it just validates the PID and our permission to signal it.
    try:
        pid = int(pid)
    except Exception:
        return True  # no pid recorded → fall back to TTL
    if pid <= 1:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, just not ours
    except Exception:
        return True


def _prune(now, ttl):
    dead = []
    for k, s in _sessions.items():
        error_expires_at = s.get("error_expires_at") or 0
        if s.get("state") == "Error" and error_expires_at > now:
            continue
        pid = s.get("pid")
        if pid:
            if not _pid_alive(pid):
                dead.append(k)
            continue
        if (now - s["updated_at"]) > ttl:
            dead.append(k)
    for k in dead:
        pid = _sessions[k].get("pid")
        if pid:
            _remember_ended_pid(pid, now)
        del _sessions[k]


def _mark_unexpected_claude_exits(now):
    # Claude's SessionEnd hook fires synchronously on normal exit and removes
    # the session. If the CLI process is gone but the session is still here,
    # it likely crashed / was SIGKILLed / lost its network. Only surface Error
    # when the agent disappeared mid-turn; if Claude was already Idle, prune it
    # directly so ordinary quits do not flash Error in the island.
    for s in _sessions.values():
        if s.get("agent") != "Claude":
            continue
        pid = s.get("pid")
        if not pid or _pid_alive(pid):
            continue
        if not s.get("turn_active") and s.get("state") not in ("Working", "Waiting"):
            continue
        if s.get("state") == "Error":
            continue
        s["state"] = "Error"
        s["turn_active"] = False
        s["turn_started_at"] = None
        s["last_event"] = "UnexpectedExit"
        s["updated_at"] = now
        s["error_expires_at"] = now + ERROR_DISPLAY_SECONDS


def _mark_unexpected_codex_exits(now):
    # Codex only deserves Error when the active turn disappears unexpectedly.
    # Ordinary Bash command failures are tool-level outcomes, not agent crashes.
    for s in _sessions.values():
        if s.get("agent") != "Codex":
            continue
        if not s.get("turn_active"):
            continue
        pid = s.get("pid")
        if not pid or _pid_alive(pid):
            continue
        s["state"] = "Error"
        s["turn_active"] = False
        s["last_event"] = "UnexpectedExit"
        s["updated_at"] = now
        s["error_expires_at"] = now + ERROR_DISPLAY_SECONDS


def _dedupe_codex_sessions():
    # Codex can report a new session_id while reusing the same long-lived CLI
    # process. Keep only the freshest session per PID so one terminal maps to
    # one visible row.
    best_by_pid = {}
    for key, s in _sessions.items():
        if s.get("agent") != "Codex":
            continue
        pid = s.get("pid")
        if not pid:
            continue
        current = best_by_pid.get(pid)
        if current is None:
            best_by_pid[pid] = key
            continue
        chosen = _sessions.get(current) or {}
        challenger = s
        chosen_rank = (0 if chosen.get("synthetic") else 1, chosen.get("updated_at", 0))
        challenger_rank = (0 if challenger.get("synthetic") else 1, challenger.get("updated_at", 0))
        if challenger_rank > chosen_rank:
            best_by_pid[pid] = key

    keep = set(best_by_pid.values())
    for key, s in list(_sessions.items()):
        if s.get("agent") != "Codex":
            continue
        pid = s.get("pid")
        if pid and key not in keep:
            del _sessions[key]


_STATE_PRIORITY = {"Error": 3, "Waiting": 2, "Working": 1, "Idle": 0}


def _path_basename(path):
    value = (path or "").strip()
    if not value:
        return ""
    return os.path.basename(value.rstrip("/")) or value


def _normalize_text(text):
    return re.sub(r"[^a-z0-9]+", "", (text or "").lower())


def _tokenize_text(text):
    return [tok for tok in re.split(r"[^a-z0-9]+", (text or "").lower()) if tok]


def _agent_title_tokens(agent):
    if agent == "Codex":
        return ("codex", "cx")
    if agent == "Claude":
        return ("claude", "cc")
    text = (agent or "").strip().lower()
    return (text,) if text else ()


def _strip_ansi(text):
    return ANSI_ESCAPE_RE.sub("", text or "")


def _decode_blob_text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        text = value.decode("utf-8", errors="ignore")
    else:
        text = str(value)
    return " ".join(_strip_ansi(text).replace("\r", " ").replace("\n", " ").split())


def _classify_agent_command(command):
    text = (command or "").strip().lower()
    if not text:
        return ""
    padded = f" {text} "
    if re.search(r"(^|[^a-z0-9])codex([^a-z0-9]|$)", padded):
        return "Codex"
    if re.search(r"(^|[^a-z0-9])claude([^a-z0-9]|$)", padded):
        return "Claude"
    if re.search(r"(^|[^a-z0-9])cc([^a-z0-9]|$)", padded):
        return "Claude"
    return ""


def _warp_tab_label(tab):
    title = (tab.get("custom_title") or "").strip()
    if title:
        return title
    ordinal = tab.get("ordinal")
    if ordinal:
        return f"Tab {ordinal}"
    return ""


def _warp_load_context():
    if not WARP_SQLITE_PATH.exists():
        return None

    conn = None
    try:
        conn = sqlite3.connect(str(WARP_SQLITE_PATH))
        conn.row_factory = sqlite3.Row

        row = conn.execute("SELECT active_window_id FROM app LIMIT 1").fetchone()
        active_window_id = row["active_window_id"] if row and row["active_window_id"] else None

        raw_tabs = conn.execute(
            """
            SELECT
              t.id AS tab_id,
              t.window_id AS window_id,
              COALESCE(t.custom_title, '') AS custom_title,
              COALESCE(tp.cwd, '') AS cwd,
              hex(tp.uuid) AS pane_uuid
            FROM tabs t
            LEFT JOIN pane_nodes pn ON pn.tab_id = t.id
            LEFT JOIN terminal_panes tp ON tp.id = pn.id
            ORDER BY t.window_id, t.id
            """
        ).fetchall()

        tabs = []
        pane_uuids = []
        ordinals = {}
        for raw in raw_tabs:
            window_id = raw["window_id"]
            ordinals[window_id] = ordinals.get(window_id, 0) + 1
            title = raw["custom_title"] or ""
            pane_uuid = (raw["pane_uuid"] or "").upper()
            tab = {
                "tab_id": raw["tab_id"],
                "window_id": window_id,
                "ordinal": ordinals[window_id],
                "custom_title": title,
                "cwd": raw["cwd"] or "",
                "pane_uuid": pane_uuid,
                "title_norm": _normalize_text(title),
                "title_tokens": tuple(_tokenize_text(title)),
                "warp_session": "",
                "agent_hint": "",
                "live_command_agent": "",
                "live_command": "",
            }
            tabs.append(tab)
            if pane_uuid:
                pane_uuids.append(pane_uuid)

        pane_meta = {}
        if pane_uuids:
            placeholders = ",".join(["?"] * len(pane_uuids))
            block_rows = conn.execute(
                f"""
                SELECT hex(pane_leaf_uuid) AS pane_uuid, block_id, stylized_command
                FROM blocks
                WHERE hex(pane_leaf_uuid) IN ({placeholders})
                ORDER BY id DESC
                """,
                pane_uuids,
            ).fetchall()
            remaining = set(pane_uuids)
            for row in block_rows:
                pane_uuid = (row["pane_uuid"] or "").upper()
                if not pane_uuid:
                    continue
                meta = pane_meta.setdefault(pane_uuid, {"warp_session": "", "agent_hint": ""})
                if not meta["warp_session"]:
                    match = re.match(r"^precmd-(\d+)-\d+$", row["block_id"] or "")
                    if match:
                        meta["warp_session"] = match.group(1)
                if not meta["agent_hint"]:
                    agent_hint = _classify_agent_command(_decode_blob_text(row["stylized_command"]))
                    if agent_hint:
                        meta["agent_hint"] = agent_hint
                if meta["warp_session"] and meta["agent_hint"] and pane_uuid in remaining:
                    remaining.remove(pane_uuid)
                if not remaining:
                    break

        live_rows = conn.execute(
            """
            SELECT command, COALESCE(pwd, '') AS pwd, CAST(session_id AS TEXT) AS warp_session
            FROM commands
            WHERE completed_ts IS NULL
            ORDER BY start_ts DESC
            """
        ).fetchall()
        live_by_session = {}
        for row in live_rows:
            agent = _classify_agent_command(row["command"] or "")
            if not agent:
                continue
            warp_session = (row["warp_session"] or "").strip()
            if not warp_session:
                continue
            live_by_session.setdefault(warp_session, []).append({
                "agent": agent,
                "command": row["command"] or "",
                "cwd": row["pwd"] or "",
            })

        for tab in tabs:
            meta = pane_meta.get(tab["pane_uuid"], {})
            tab["warp_session"] = meta.get("warp_session", "")
            tab["agent_hint"] = meta.get("agent_hint", "")
            live = live_by_session.get(tab["warp_session"], [])
            for item in live:
                if item["cwd"] and tab["cwd"] and item["cwd"] != tab["cwd"]:
                    continue
                tab["live_command_agent"] = item["agent"]
                tab["live_command"] = item["command"]
                break

        return {
            "active_window_id": active_window_id,
            "tabs": tabs,
        }
    except Exception:
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def _warp_active_tab_ordinal(window_id):
    if window_id is None or not WARP_SQLITE_PATH.exists():
        return 0

    conn = None
    try:
        conn = sqlite3.connect(str(WARP_SQLITE_PATH))
        row = conn.execute(
            "SELECT active_tab_index FROM windows WHERE id = ?",
            (window_id,),
        ).fetchone()
        if not row or row[0] is None:
            return 0
        return int(row[0]) + 1
    except Exception:
        return 0
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def _warp_send_tab_shortcut(key_code, bounce_if_frontmost=False):
    script = """on run argv
  set keyCodeNumber to (item 1 of argv) as integer
  set shouldBounceIfFrontmost to false
  if (count of argv) > 1 then
    set shouldBounceIfFrontmost to ((item 2 of argv) as text) is "1"
  end if
  set didBounce to false

  tell application "System Events"
    if exists process "Warp" then
      tell process "Warp"
        if shouldBounceIfFrontmost and (frontmost is true) then
          set didBounce to true
        end if
      end tell
    end if
  end tell

  if didBounce then
    tell application "Finder" to activate
    tell application "System Events"
      tell process "Finder"
        set waitCount to 0
        repeat while (frontmost is false) and (waitCount < 30)
          delay 0.02
          set waitCount to waitCount + 1
        end repeat
      end tell
    end tell
  end if

  tell application "Warp" to activate
  tell application "System Events"
    tell process "Warp"
      set frontmost to true
      set waitCount to 0
      repeat while (frontmost is false) and (waitCount < 30)
        delay 0.02
        set waitCount to waitCount + 1
      end repeat
    end tell
  end tell
  delay 0.06
  tell application "System Events"
    tell process "Warp"
      key code keyCodeNumber using {command down}
    end tell
  end tell
  if didBounce then
    return "focused:bounced"
  end if
  return "focused"
end run
"""
    args = [key_code]
    if bounce_if_frontmost:
        args.append("1")
    return _run_osascript(script, args, timeout=4.0)


def _warp_score_tab(session, tab):
    score = 0
    session_agent = (session.get("agent") or "").strip()
    session_cwd = (session.get("cwd") or "").strip()
    tab_cwd = (tab.get("cwd") or "").strip()
    repo = _path_basename(session_cwd)
    repo_norm = _normalize_text(repo)
    title_norm = tab.get("title_norm") or ""
    title_tokens = set(tab.get("title_tokens") or ())
    agent_tokens = set(_agent_title_tokens(session_agent))

    if session_cwd and tab_cwd:
        if os.path.normpath(session_cwd) == os.path.normpath(tab_cwd):
            score += 70
        elif repo and repo == _path_basename(tab_cwd):
            score += 15

    if repo_norm and title_norm:
        if title_norm == repo_norm:
            score += 110
        elif repo_norm in title_norm:
            score += 70

    if agent_tokens:
        if title_tokens.intersection(agent_tokens):
            score += 120
        elif title_tokens.intersection({"claude", "cc", "codex", "cx"}):
            score -= 90

    if tab.get("live_command_agent") == session_agent:
        score += 220
    elif tab.get("live_command_agent"):
        score -= 120

    if tab.get("agent_hint") == session_agent:
        score += 80
    elif tab.get("agent_hint"):
        score -= 40

    if tab.get("custom_title"):
        score += 10

    return score


def _resolve_warp_tab(session, warp_context):
    if not warp_context:
        return None

    active_window_id = warp_context.get("active_window_id")
    tabs = warp_context.get("tabs") or []
    if active_window_id is not None:
        tabs = [tab for tab in tabs if tab.get("window_id") == active_window_id]
    if not tabs:
        return None

    ranked = []
    for tab in tabs:
        score = _warp_score_tab(session, tab)
        if score > 0:
            ranked.append((score, tab))

    if not ranked:
        return None

    ranked.sort(key=lambda item: (item[0], bool(item[1].get("custom_title"))), reverse=True)
    top_score, top_tab = ranked[0]
    second_score = ranked[1][0] if len(ranked) > 1 else -999
    if top_score < 140:
        return None
    if second_score == top_score:
        return None
    if second_score >= 140 and (top_score - second_score) < 35:
        return None
    return dict(top_tab)


def _snapshot(ttl):
    now = time.time()
    codex_candidates = _scan_codex_startup_candidates(now)
    claude_candidates = _scan_claude_startup_candidates(now)
    with _lock:
        _gc_recently_ended(now)
        _decay_working(now)
        _sync_codex_startup_sessions(now, codex_candidates)
        _sync_claude_startup_sessions(now, claude_candidates)
        _mark_unexpected_codex_exits(now)
        _mark_unexpected_claude_exits(now)
        _prune(now, ttl)
        _dedupe_codex_sessions()
        sessions = [dict(s) for s in _sessions.values()]
    warp_context = _warp_load_context()
    for s in sessions:
        terminal = (s.get("terminal") or "").strip()
        if not terminal:
            terminal = _infer_terminal_from_pid(s.get("pid"))
            if terminal:
                s["terminal"] = terminal
        s["focusable"] = bool(terminal)
        if terminal == "Warp":
            target = _resolve_warp_tab(s, warp_context)
            if target:
                s["tab_title"] = _warp_tab_label(target)
                s["tab_ordinal"] = target.get("ordinal")
                s["tab_window_id"] = target.get("window_id")
                s["focusable"] = bool(target.get("ordinal") in WARP_TAB_KEY_CODES)
            else:
                s["tab_title"] = ""
                s["tab_ordinal"] = 0
                s["tab_window_id"] = None
                s["focusable"] = False
        pending = _pending_permission_for_session(s.get("agent") or "", s.get("session_id") or "")
        if pending:
            s["pending_permission"] = pending
            # Permission outranks any stale Working/Idle so the UI shows the
            # question prominently.
            s["state"] = "Waiting"
    sessions.sort(key=lambda s: (-_STATE_PRIORITY.get(s["state"], 0), -s["updated_at"]))
    if sessions:
        top = sessions[0]
        legacy_state = top["state"]
        legacy_updated = top["updated_at"]
    else:
        legacy_state = "Idle"
        legacy_updated = now
    return {
        "sessions": sessions,
        "state": legacy_state,
        "updated_at": legacy_updated,
    }


def _apply_event(data):
    state = data.get("state")
    agent = data.get("agent") or "Claude"
    session_id = data.get("session_id") or "default"
    event = data.get("event") or ""
    key = (agent, session_id)
    try:
        incoming_pid = int(data.get("pid") or 0) or None
    except Exception:
        incoming_pid = None
    # "Ended" is a pseudo-state that removes the session outright — fired by
    # Claude Code's SessionEnd hook so Ctrl+C quits don't leave stale pills.
    if state == "Ended":
        now = time.time()
        with _lock:
            removed = []
            if incoming_pid:
                for other_key, other in list(_sessions.items()):
                    if other.get("agent") != agent:
                        continue
                    if other.get("pid") != incoming_pid:
                        continue
                    removed.append(_sessions.pop(other_key, None))
            existing = _sessions.pop(key, None)
            if existing is not None:
                removed.append(existing)
            removed = [item for item in removed if item is not None]
            existed = bool(removed)
            ended_pid = incoming_pid
            if not ended_pid:
                for item in removed:
                    if item.get("pid"):
                        ended_pid = item.get("pid")
                        break
            if ended_pid:
                _remember_ended_pid(ended_pid, now)
        return True, {"ok": True, "state": "Ended", "agent": agent, "session_id": session_id, "removed": existed}
    if state not in VALID_STATES:
        return False, {"error": "invalid state", "got": state}
    now = time.time()
    incoming_turn_id = data.get("turn_id") or None
    incoming_last_assistant_message = (
        data["last_assistant_message"] if "last_assistant_message" in data
        else None
    )
    with _lock:
        existing = _sessions.get(key) or {}
        if agent == "Codex" and incoming_pid:
            for other_key, other in list(_sessions.items()):
                if other_key == key:
                    continue
                if other.get("agent") != "Codex":
                    continue
                if other.get("pid") != incoming_pid:
                    continue
                if other.get("synthetic") and not existing:
                    existing = dict(other)
                _sessions.pop(other_key, None)
        elif agent == "Claude" and incoming_pid:
            # A single Claude Code process only ever owns one live session at a
            # time. Seeing a new session_id under the same PID means the prior
            # one is abandoned (e.g. `/clear`, or a Stop we missed on ESC),
            # and any synthetic placeholder from the startup scanner is also
            # redundant. Drop them all and inherit cwd/title if useful.
            for other_key, other in list(_sessions.items()):
                if other_key == key:
                    continue
                if other.get("agent") != "Claude":
                    continue
                if other.get("pid") != incoming_pid:
                    continue
                if not existing:
                    existing = dict(other)
                _sessions.pop(other_key, None)
        effective_state = state
        turn_active = existing.get("turn_active", False)
        turn_started_at = existing.get("turn_started_at")
        error_expires_at = existing.get("error_expires_at")

        if agent == "Codex":
            if event == "UserPromptSubmit":
                effective_state = "Working"
                turn_active = True
                turn_started_at = now
            elif event in ("PreToolUse", "PostToolUse"):
                effective_state = "Working"
                turn_active = True
                if not turn_started_at:
                    turn_started_at = now
            elif event == "Stop":
                effective_state = "Idle"
                turn_active = False
                turn_started_at = None
            elif event == "SessionStart":
                effective_state = "Idle"
                turn_active = False
                turn_started_at = None
            elif state == "Working" and incoming_turn_id:
                turn_active = True
                if not turn_started_at:
                    turn_started_at = now

            if event:
                error_expires_at = None
        elif agent == "Claude":
            if state in ("Working", "Waiting"):
                turn_active = True
                if not turn_started_at:
                    turn_started_at = now
            elif state == "Idle":
                turn_active = False
                turn_started_at = None

            if event:
                error_expires_at = None

        if agent != "Codex" and state == "Idle":
            turn_active = False
            turn_started_at = None

        resolved_terminal = (
            data.get("terminal") or
            existing.get("terminal") or
            _infer_terminal_from_pid(incoming_pid or existing.get("pid")) or
            ""
        )

        _sessions[key] = {
            "agent": agent,
            "session_id": session_id,
            "state": effective_state,
            "title": (data.get("title") or existing.get("title") or "")[:200],
            "cwd": data.get("cwd") or existing.get("cwd") or "",
            "terminal": resolved_terminal,
            "pid": incoming_pid or existing.get("pid"),
            "turn_id": incoming_turn_id or existing.get("turn_id"),
            "turn_active": turn_active,
            "turn_started_at": turn_started_at,
            "last_event": event or existing.get("last_event"),
            "last_assistant_message": (
                incoming_last_assistant_message
                if "last_assistant_message" in data
                else existing.get("last_assistant_message")
            ),
            "error_expires_at": error_expires_at,
            "updated_at": now,
            "synthetic": False,
            "transcript_path": (
                data.get("transcript_path") or existing.get("transcript_path") or ""
            ),
        }
    return True, {"ok": True, "state": effective_state, "agent": agent, "session_id": session_id}


# ---------------------------------------------------------------------------
# Claude Code settings.json hook management
# ---------------------------------------------------------------------------

def _cc_event_cmd(state):
    # Invoke the unified hook script; quoted because path contains a space.
    return f"'{CC_HOOK_SCRIPT}' {state} {CC_HOOK_MARKER}"


CC_PERMISSION_HOOK_URL = f"http://127.0.0.1:{PORT}/hooks/permission"
CC_PERMISSION_HOOK_TIMEOUT = int(os.environ.get("AGENTS_STATUS_CC_PERMISSION_HTTP_TIMEOUT", "600"))


def _cc_canonical_events():
    # Every event goes through cc-event-hook.sh so the payload is enriched
    # with session_id / cwd / title / terminal before it reaches the bridge.
    # PostToolUse uses Auto so Working vs Error is inferred from tool_response.
    # SubagentStop intentionally omitted: sub-agents finishing would otherwise
    # flip the parent session to Idle while the main agent is still working.
    return {
        "SessionStart":        _cc_event_cmd("Idle"),
        "UserPromptSubmit":    _cc_event_cmd("Working"),
        "PreToolUse":          _cc_event_cmd("Working"),
        "PostToolUse":         _cc_event_cmd("Auto"),
        # PostToolUseFailure is Claude Code's only reliable ESC-interrupt
        # signal: its payload carries is_interrupt=true when the user hit
        # ESC mid-tool. The hook script decodes that and emits Idle.
        "PostToolUseFailure":  _cc_event_cmd("ToolFail"),
        "Notification":        _cc_event_cmd("Waiting"),
        "Stop":                _cc_event_cmd("Idle"),
        "SessionEnd":          _cc_event_cmd("Ended"),
    }


def _cc_canonical_http_events():
    # PermissionRequest is a blocking hook — Claude waits for our response
    # before proceeding. We intercept AskUserQuestion to let the user pick an
    # option from the island; other tool permissions pass through allow.
    return {
        "PermissionRequest": {
            "type": "http",
            "url": CC_PERMISSION_HOOK_URL,
            "timeout": CC_PERMISSION_HOOK_TIMEOUT,
        },
    }


def _cc_is_our_group(group):
    try:
        for h in (group.get("hooks") or []):
            cmd = h.get("command") or ""
            if CC_HOOK_MARKER in cmd:
                return True
            if CC_HOOK_SCRIPT and CC_HOOK_SCRIPT in cmd:
                return True
            # Legacy pre-marker installs.
            if "cc-posttool-hook.sh" in cmd or "cc-event-hook.sh" in cmd:
                return True
            if f"127.0.0.1:{PORT}/event" in cmd:
                return True
            # HTTP hooks (PermissionRequest) — match on our bridge URL.
            url = h.get("url") or ""
            if f"127.0.0.1:{PORT}/hooks/" in url:
                return True
    except Exception:
        pass
    return False


def _load_cc_settings():
    if not CC_SETTINGS_PATH.exists():
        return {}
    try:
        text = CC_SETTINGS_PATH.read_text()
        return json.loads(text) if text.strip() else {}
    except Exception as e:
        sys.stderr.write(f"failed to parse {CC_SETTINGS_PATH}: {e}\n")
        return {}


def _save_cc_settings(d):
    CC_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = CC_SETTINGS_PATH.with_suffix(CC_SETTINGS_PATH.suffix + ".tmp")
    tmp.write_text(json.dumps(d, indent=2) + "\n")
    tmp.replace(CC_SETTINGS_PATH)


def _backup_once(path, suffix):
    if not path.exists():
        return
    bp = path.with_suffix(path.suffix + suffix)
    if not bp.exists():
        shutil.copy2(path, bp)


def cc_install():
    # Purge first so events we no longer manage (e.g. a previous version's
    # SubagentStop hook) get cleaned up before we add the canonical set.
    cc_uninstall()
    _backup_once(CC_SETTINGS_PATH, BACKUP_SUFFIX)
    d = _load_cc_settings()
    hooks = d.setdefault("hooks", {})
    installed = []
    for event_name, command in _cc_canonical_events().items():
        bucket = hooks.setdefault(event_name, [])
        if not isinstance(bucket, list):
            bucket = []
            hooks[event_name] = bucket
        bucket.append({"hooks": [{"type": "command", "command": command}]})
        installed.append(event_name)
    for event_name, http_spec in _cc_canonical_http_events().items():
        bucket = hooks.setdefault(event_name, [])
        if not isinstance(bucket, list):
            bucket = []
            hooks[event_name] = bucket
        bucket.append({"hooks": [dict(http_spec)]})
        installed.append(event_name)
    _save_cc_settings(d)
    return installed


def cc_uninstall():
    if not CC_SETTINGS_PATH.exists():
        return []
    d = _load_cc_settings()
    hooks = d.get("hooks") or {}
    if not isinstance(hooks, dict):
        return []
    removed = []
    for event_name in list(hooks.keys()):
        bucket = hooks.get(event_name)
        if not isinstance(bucket, list):
            continue
        before = len(bucket)
        bucket[:] = [g for g in bucket if not _cc_is_our_group(g)]
        if len(bucket) != before:
            removed.append(event_name)
        if not bucket:
            del hooks[event_name]
    if not hooks:
        d.pop("hooks", None)
    _save_cc_settings(d)
    return removed


def cc_status():
    d = _load_cc_settings()
    hooks = d.get("hooks") or {}
    if not isinstance(hooks, dict):
        return {"installed": False, "events": []}
    present = []
    for event_name, bucket in hooks.items():
        if isinstance(bucket, list) and any(_cc_is_our_group(g) for g in bucket):
            present.append(event_name)
    primary = {"UserPromptSubmit", "PreToolUse", "PostToolUseFailure", "Stop", "SessionEnd", "PermissionRequest"}
    return {"installed": primary.issubset(set(present)), "events": sorted(present)}


# ---------------------------------------------------------------------------
# Codex ~/.codex/config.toml + ~/.codex/hooks.json management
# ---------------------------------------------------------------------------

_TOML_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*(?:#.*)?$")
_TOML_KEY_RE = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*=")


def _codex_read_lines():
    if not CODEX_CONFIG_PATH.exists():
        return []
    try:
        return CODEX_CONFIG_PATH.read_text().splitlines()
    except Exception as e:
        sys.stderr.write(f"failed to read {CODEX_CONFIG_PATH}: {e}\n")
        return []


def _codex_write_lines(lines):
    CODEX_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not any(ln.strip() for ln in lines):
        try:
            CODEX_CONFIG_PATH.unlink()
        except FileNotFoundError:
            pass
        return
    tmp = CODEX_CONFIG_PATH.with_suffix(CODEX_CONFIG_PATH.suffix + ".tmp")
    text = "\n".join(lines).rstrip() + "\n"
    tmp.write_text(text)
    tmp.replace(CODEX_CONFIG_PATH)


def _codex_section_name(line):
    m = _TOML_SECTION_RE.match(line)
    return m.group(1).strip() if m else None


def _codex_key_name(line):
    content = line.split("#", 1)[0]
    m = _TOML_KEY_RE.match(content)
    return m.group(1).strip() if m else None


def _codex_bool_value(line, key):
    content = line.split("#", 1)[0]
    m = re.match(rf"^\s*{re.escape(key)}\s*=\s*(true|false)\s*$", content, re.IGNORECASE)
    if not m:
        return None
    return m.group(1).lower() == "true"


def _codex_find_section(lines, name):
    start = None
    end = len(lines)
    for i, line in enumerate(lines):
        section_name = _codex_section_name(line)
        if section_name == name:
            start = i
            continue
        if start is not None and section_name is not None:
            end = i
            break
    return start, end


def _codex_feature_line():
    return f"codex_hooks = true  {CODEX_FEATURE_MARKER}"


def _codex_strip_managed_notify(lines):
    out = []
    removed = False
    for line in lines:
        if CODEX_MARKER in line and _codex_key_name(line) == "notify":
            removed = True
            continue
        out.append(line)
    return out, removed


def _codex_restore_feature_lines(lines):
    out = []
    changed = False
    for line in lines:
        if line.startswith(CODEX_FEATURE_RESTORE_PREFIX):
            out.append(line[len(CODEX_FEATURE_RESTORE_PREFIX):])
            changed = True
            continue
        if CODEX_FEATURE_MARKER in line:
            changed = True
            continue
        out.append(line)
    return out, changed


def _codex_prune_empty_features_section(lines):
    start, end = _codex_find_section(lines, "features")
    if start is None:
        return lines
    if any(lines[i].strip() for i in range(start + 1, end)):
        return lines
    new = lines[:start] + lines[end:]
    while len(new) >= 2 and new[-1] == "" and new[-2] == "":
        new.pop()
    return new


def _codex_install_feature_flag(lines):
    lines, _ = _codex_restore_feature_lines(lines)
    lines, _ = _codex_strip_managed_notify(lines)
    start, end = _codex_find_section(lines, "features")
    if start is None:
        out = list(lines)
        if out and out[-1].strip():
            out.append("")
        out.extend(["[features]", _codex_feature_line()])
        return out
    for i in range(start + 1, end):
        if _codex_key_name(lines[i]) != "codex_hooks":
            continue
        value = _codex_bool_value(lines[i], "codex_hooks")
        if value is True:
            return lines
        original = lines[i]
        return lines[:i] + [f"{CODEX_FEATURE_RESTORE_PREFIX}{original}", _codex_feature_line()] + lines[i + 1:]
    return lines[:start + 1] + [_codex_feature_line()] + lines[start + 1:]


def _codex_uninstall_feature_flag(lines):
    lines, changed_restore = _codex_restore_feature_lines(lines)
    lines, changed_notify = _codex_strip_managed_notify(lines)
    lines = _codex_prune_empty_features_section(lines)
    return lines, (changed_restore or changed_notify)


def _codex_feature_enabled(lines):
    start, end = _codex_find_section(lines, "features")
    if start is None:
        return False
    for i in range(start + 1, end):
        if _codex_key_name(lines[i]) != "codex_hooks":
            continue
        return _codex_bool_value(lines[i], "codex_hooks") is True
    return False


def _codex_event_cmd():
    return f"'{CODEX_HOOK_SCRIPT}' {CODEX_HOOK_MARKER}"


def _codex_canonical_events():
    def group(matcher=None):
        entry = {"hooks": [{"type": "command", "command": _codex_event_cmd()}]}
        if matcher is not None:
            entry["matcher"] = matcher
        return [entry]

    return {
        "SessionStart": group("startup|resume"),
        "UserPromptSubmit": group(),
        "PreToolUse": group("Bash"),
        "PostToolUse": group("Bash"),
        "Stop": group(),
    }


def _codex_load_hooks():
    if not CODEX_HOOKS_PATH.exists():
        return {}
    try:
        text = CODEX_HOOKS_PATH.read_text()
        return json.loads(text) if text.strip() else {}
    except Exception as e:
        sys.stderr.write(f"failed to parse {CODEX_HOOKS_PATH}: {e}\n")
        return {}


def _codex_save_hooks(d):
    CODEX_HOOKS_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not d:
        try:
            CODEX_HOOKS_PATH.unlink()
        except FileNotFoundError:
            pass
        return
    tmp = CODEX_HOOKS_PATH.with_suffix(CODEX_HOOKS_PATH.suffix + ".tmp")
    tmp.write_text(json.dumps(d, indent=2) + "\n")
    tmp.replace(CODEX_HOOKS_PATH)


def _codex_is_our_group(group):
    try:
        for h in (group.get("hooks") or []):
            cmd = h.get("command") or ""
            if CODEX_HOOK_MARKER in cmd:
                return True
            if CODEX_HOOK_SCRIPT and CODEX_HOOK_SCRIPT in cmd:
                return True
            if "codex-notify-hook.sh" in cmd:
                return True
    except Exception:
        pass
    return False


def _codex_remove_managed_hooks(d):
    hooks = d.get("hooks") or {}
    if not isinstance(hooks, dict):
        return d, []
    removed = []
    for event_name in list(hooks.keys()):
        bucket = hooks.get(event_name)
        if not isinstance(bucket, list):
            continue
        before = len(bucket)
        bucket[:] = [g for g in bucket if not _codex_is_our_group(g)]
        if len(bucket) != before:
            removed.append(event_name)
        if not bucket:
            del hooks[event_name]
    if not hooks:
        d.pop("hooks", None)
    return d, removed


def _find_binary(name):
    """Locate a user-installed CLI that probably isn't on the launchd PATH.

    macOS apps start with a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
    so `shutil.which` misses anything in Homebrew, `~/.local/bin`, npm global
    bins, asdf/nvm, etc. This walks a widened candidate list, then falls
    back to asking the user's login shell for its PATH — that's where the
    CLI lives when the user runs it in Terminal.
    """
    # Fast path — already on the process PATH.
    hit = shutil.which(name)
    if hit:
        return hit

    home = pathlib.Path.home()
    candidate_dirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/local/sbin",
        str(home / ".local" / "bin"),
        str(home / ".bun" / "bin"),
        str(home / ".cargo" / "bin"),
        str(home / ".deno" / "bin"),
        str(home / "bin"),
        str(home / ".volta" / "bin"),
    ]
    # Include any node version managers' current shim dirs (best-effort).
    for nm in (home / ".nvm" / "versions" / "node").glob("*/bin") if (home / ".nvm").exists() else []:
        candidate_dirs.append(str(nm))

    for d in candidate_dirs:
        candidate = pathlib.Path(d) / name
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)

    # Last resort — ask the user's shell. Login-mode (-l) sources rc files so
    # we see the same PATH that Terminal does.
    shell = os.environ.get("SHELL") or "/bin/zsh"
    try:
        res = subprocess.run(
            [shell, "-lc", f"command -v {shlex.quote(name)}"],
            capture_output=True,
            text=True,
            timeout=3.0,
            check=False,
        )
    except Exception:
        return None
    path = (res.stdout or "").strip().splitlines()[-1:] if res.stdout else []
    if path and os.access(path[0], os.X_OK):
        return path[0]
    return None


def codex_install():
    # Preflight: if the codex CLI isn't on PATH the hooks will never fire —
    # installing them silently is worse than failing loudly. Either produces a
    # clear user-facing error via the HTTP route's 500 + error message path.
    if _find_binary("codex") is None:
        raise RuntimeError(
            "Codex CLI not found — install codex first (https://openai.com/codex) "
            "and re-toggle this setting"
        )
    # Hook script must be present AND executable, otherwise codex will try to
    # invoke a missing binary and every hook call will fail silently.
    if not CODEX_HOOK_SCRIPT or not pathlib.Path(CODEX_HOOK_SCRIPT).exists():
        raise RuntimeError(
            f"Codex hook script missing at {CODEX_HOOK_SCRIPT or '<unset>'} — "
            "reinstall the extension bundle"
        )
    if not os.access(CODEX_HOOK_SCRIPT, os.X_OK):
        raise RuntimeError(
            f"Codex hook script is not executable ({CODEX_HOOK_SCRIPT}) — "
            "run `chmod +x` on it and retry"
        )

    _backup_once(CODEX_CONFIG_PATH, BACKUP_SUFFIX)
    _backup_once(CODEX_HOOKS_PATH, BACKUP_SUFFIX)

    lines = _codex_install_feature_flag(_codex_read_lines())
    _codex_write_lines(lines)

    d, _ = _codex_remove_managed_hooks(_codex_load_hooks())
    hooks = d.setdefault("hooks", {})
    installed = []
    for event_name, groups in _codex_canonical_events().items():
        bucket = hooks.setdefault(event_name, [])
        if not isinstance(bucket, list):
            bucket = []
            hooks[event_name] = bucket
        bucket.extend(groups)
        installed.append(event_name)
    _codex_save_hooks(d)
    return installed


def codex_uninstall():
    removed = []
    if CODEX_CONFIG_PATH.exists():
        lines, changed = _codex_uninstall_feature_flag(_codex_read_lines())
        if changed:
            removed.extend(CODEX_EVENTS)
        _codex_write_lines(lines)

    if CODEX_HOOKS_PATH.exists():
        d, hook_removed = _codex_remove_managed_hooks(_codex_load_hooks())
        if hook_removed:
            removed.extend(hook_removed)
        _codex_save_hooks(d)

    deduped = []
    for event_name in CODEX_EVENTS:
        if event_name in removed and event_name not in deduped:
            deduped.append(event_name)
    return deduped


def codex_status():
    lines = _codex_read_lines()
    d = _codex_load_hooks()
    hooks = d.get("hooks") or {}
    if not isinstance(hooks, dict):
        hooks = {}
    present = []
    for event_name in CODEX_EVENTS:
        bucket = hooks.get(event_name)
        if isinstance(bucket, list) and any(_codex_is_our_group(g) for g in bucket):
            present.append(event_name)
    installed = _codex_feature_enabled(lines) and set(CODEX_EVENTS).issubset(set(present))
    return {"installed": installed, "events": present}


# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------

def _build_response(code, reason, payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    chunk_header = f"{len(body):X}\r\n".encode("ascii")
    chunked_body = chunk_header + body + b"\r\n0\r\n\r\n"
    headers = (
        f"HTTP/1.1 {code} {reason}\r\n"
        f"Content-Type: application/json\r\n"
        f"Transfer-Encoding: chunked\r\n"
        f"Cache-Control: no-store, no-cache, must-revalidate\r\n"
        f"Pragma: no-cache\r\n"
        f"Expires: 0\r\n"
        f"Vary: *\r\n"
        f"Access-Control-Allow-Origin: *\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode("ascii")
    return headers + chunked_body


def _parse_query(path):
    if "?" not in path:
        return path, {}
    p, q = path.split("?", 1)
    try:
        params = {k: v[0] for k, v in urllib.parse.parse_qs(q, keep_blank_values=True).items()}
    except Exception:
        params = {}
    return p, params


def _agent_param(params):
    a = (params.get("agent") or "claude").strip().lower()
    return a if a in ("claude", "codex") else "claude"


def _ttl_param(params):
    try:
        v = float(params.get("ttl", SESSION_TTL_DEFAULT))
        return max(30.0, min(v, 24 * 3600.0))
    except Exception:
        return SESSION_TTL_DEFAULT


def _tty_for_pid(pid):
    try:
        pid = int(pid)
    except Exception:
        return ""
    if pid <= 1:
        return ""
    try:
        res = subprocess.run(
            ["ps", "-o", "tty=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=0.6,
            check=False,
        )
    except Exception:
        return ""
    tty = (res.stdout or "").strip()
    if tty in ("", "?", "??"):
        return ""
    return tty


def _run_osascript(script, args=None, timeout=4.0):
    argv = ["osascript", "-"]
    if args:
        argv.extend(str(arg) for arg in args)
    try:
        res = subprocess.run(
            argv,
            input=script,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except Exception as e:
        return False, str(e)
    output = (res.stdout or res.stderr or "").strip()
    if res.returncode != 0:
        return False, output or f"osascript exited {res.returncode}"
    return True, output


def _activate_app(app_name):
    if not app_name:
        return False, "missing app"
    try:
        res = subprocess.run(
            ["open", "-a", app_name],
            capture_output=True,
            text=True,
            timeout=3.0,
            check=False,
        )
    except Exception as e:
        return False, str(e)
    if res.returncode != 0:
        detail = (res.stderr or res.stdout or "").strip() or f"open -a failed ({res.returncode})"
        return False, detail
    return True, "activated"


def _focus_warp_tab(session):
    warp_context = _warp_load_context()
    target = _resolve_warp_tab(session, warp_context)
    if not target:
        return False, {"error": "warp tab not found", "terminal": "Warp"}

    ordinal = target.get("ordinal")
    key_code = WARP_TAB_KEY_CODES.get(ordinal)
    if not key_code:
        return False, {
            "error": "warp tab index unsupported",
            "terminal": "Warp",
            "tab_title": _warp_tab_label(target),
            "tab_ordinal": ordinal,
        }

    if _warp_active_tab_ordinal(target.get("window_id")) == ordinal:
        ok, detail = _activate_app("Warp")
        if not ok:
            return False, {"error": "unable to activate warp", "terminal": "Warp", "detail": detail}
        return True, {
            "ok": True,
            "terminal": "Warp",
            "method": "warp-activate",
            "tab_title": _warp_tab_label(target),
            "tab_ordinal": ordinal,
        }

    ok, detail = _warp_send_tab_shortcut(key_code, True)
    if not ok:
        return False, {
            "error": "unable to switch warp tab",
            "terminal": "Warp",
            "detail": detail,
            "tab_title": _warp_tab_label(target),
            "tab_ordinal": ordinal,
        }
    return True, {
        "ok": True,
        "terminal": "Warp",
        "method": "focused:bounced" == detail and "warp-tab-shortcut-bounce" or "warp-tab-shortcut",
        "tab_title": _warp_tab_label(target),
        "tab_ordinal": ordinal,
    }


def _ghostty_focus_targets(session):
    targets = []

    def add(val):
        if not val:
            return
        text = str(val).strip()
        if not text or text in targets:
            return
        targets.append(text)

    cwd = (session.get("cwd") or "").rstrip("/")
    if cwd:
        parts = [p for p in cwd.split("/") if p]
        if parts:
            add(parts[-1])
        add(cwd)
    add(session.get("title"))
    agent = (session.get("agent") or "").strip()
    if agent:
        add(agent.lower())
    return targets


_GHOSTTY_FOCUS_SCRIPT = """on run argv
  tell application "Ghostty" to activate
  delay 0.08
  set matchedIndex to 0
  set matchedTitle to ""
  tell application "System Events"
    tell process "Ghostty"
      try
        set wins to windows
        set winCount to count of wins
        repeat with i from 1 to winCount
          set w to item i of wins
          set winTitle to ""
          try
            set winTitle to (title of w) as text
          end try
          if winTitle is "" then
            try
              set winTitle to (name of w) as text
            end try
          end if
          if winTitle is not "" then
            repeat with tgt in argv
              set needle to tgt as text
              if needle is not "" and winTitle contains needle then
                try
                  perform action "AXRaise" of w
                end try
                set matchedIndex to i
                set matchedTitle to winTitle
                exit repeat
              end if
            end repeat
            if matchedIndex is not 0 then exit repeat
          end if
        end repeat
      end try
    end tell
  end tell
  return (matchedIndex as text) & "|" & matchedTitle
end run
"""


def _focus_ghostty_tab(session):
    ok, detail = _activate_app("Ghostty")
    if not ok:
        return False, {"error": "unable to activate ghostty", "terminal": "Ghostty", "detail": detail}

    targets = _ghostty_focus_targets(session)
    if not targets:
        return True, {"ok": True, "terminal": "Ghostty", "method": "app-activate"}

    ok_script, output = _run_osascript(_GHOSTTY_FOCUS_SCRIPT, targets, timeout=3.0)
    if ok_script and output and not output.startswith("0|"):
        parts = output.split("|", 1)
        tab_title = parts[1] if len(parts) > 1 else ""
        return True, {
            "ok": True,
            "terminal": "Ghostty",
            "method": "ghostty-window-raise",
            "tab_title": tab_title,
        }
    return True, {"ok": True, "terminal": "Ghostty", "method": "app-activate"}


def _focus_terminal_app_session(session):
    tty = _tty_for_pid(session.get("pid"))
    if not tty:
        return _activate_app("Terminal")
    script = """on run argv
  set targetTTY to item 1 of argv
  tell application "Terminal"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        set tabTTY to tty of t
        if tabTTY is targetTTY or tabTTY is ("/dev/" & targetTTY) then
          set selected of t to true
          set frontmost of w to true
          return "focused"
        end if
      end repeat
    end repeat
  end tell
  error "TTY not found: " & targetTTY
end run
"""
    return _run_osascript(script, [tty], timeout=5.0)


def _focus_session_terminal(session):
    terminal = (session.get("terminal") or "").strip()
    if not terminal:
        terminal = _infer_terminal_from_pid(session.get("pid"))
        if terminal:
            session["terminal"] = terminal
    if terminal == "Warp":
        return _focus_warp_tab(session)
    elif terminal == "Ghostty":
        return _focus_ghostty_tab(session)
    elif terminal == "Terminal":
        ok, detail = _focus_terminal_app_session(session)
        if ok:
            return True, {"ok": True, "terminal": terminal, "method": "terminal-tty"}

    app_name = TERMINAL_APP_NAMES.get(terminal) or terminal
    if app_name:
        ok, activate_detail = _activate_app(app_name)
        if ok:
            return True, {"ok": True, "terminal": terminal or app_name, "method": "app-activate"}
        return False, {"error": "unable to focus session", "terminal": terminal or "", "detail": activate_detail}
    return False, {"error": "unable to focus session", "terminal": terminal or "", "detail": "no focus strategy"}


def _focus_session_request(data):
    agent = data.get("agent") or "Claude"
    session_id = data.get("session_id") or "default"
    key = (agent, session_id)
    with _lock:
        session = dict(_sessions.get(key) or {})
    if not session:
        return False, {"error": "session not found", "agent": agent, "session_id": session_id}
    return _focus_session_terminal(session)


_ALERT_SOUNDS = {
    "start": "/System/Library/Sounds/Frog.aiff",
    "stop":  "/System/Library/Sounds/Hero.aiff",
}


def _play_alert_sound(tone):
    path = _ALERT_SOUNDS.get(tone)
    if not path:
        return None
    afplay = shutil.which("afplay") or "/usr/bin/afplay"
    try:
        subprocess.Popen(
            [afplay, path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        return True
    except Exception as e:
        sys.stderr.write(f"sound play failed: {e}\n")
        sys.stderr.flush()
        return False


def _set_session_waiting_for_permission(agent, session_id, permission_id, ts):
    """Flip the matching session to Waiting and tag it with the permission id
    so /state callers can correlate the pending prompt to its session row."""
    if not session_id:
        return
    with _lock:
        for key, s in _sessions.items():
            if key[0] != agent:
                continue
            if key[1] != session_id and s.get("session_id") != session_id:
                continue
            s["state"] = "Waiting"
            s["pending_permission_id"] = permission_id
            s["updated_at"] = ts
            break


def _clear_session_permission_tag(permission_id):
    if not permission_id:
        return
    with _lock:
        for s in _sessions.values():
            if s.get("pending_permission_id") == permission_id:
                s.pop("pending_permission_id", None)


def _handle_permission_hook(body):
    """Blocking PermissionRequest hook handler. For AskUserQuestion, we suspend
    the hook thread until the extension calls /permission/resolve with the
    chosen option. Any other tool is waved through with `allow` so regular
    Claude tool permissions keep their existing behaviour."""
    tool_name = (body.get("tool_name") or "").strip()
    session_id = body.get("session_id") or body.get("sessionId") or ""
    tool_input = body.get("tool_input") or {}

    if tool_name != "AskUserQuestion":
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }

    questions = tool_input.get("questions") or []
    if not isinstance(questions, list) or not questions:
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }

    permission_id = str(uuid.uuid4())
    event = threading.Event()
    created_at = time.time()
    entry = {
        "session_id": session_id,
        "agent": "Claude",
        "tool_name": tool_name,
        "tool_input": tool_input,
        "questions": questions,
        "event": event,
        "decision": None,
        "created_at": created_at,
    }
    with _pending_permissions_lock:
        _pending_permissions[permission_id] = entry

    _set_session_waiting_for_permission("Claude", session_id, permission_id, created_at)

    try:
        signalled = event.wait(PERMISSION_HOOK_TIMEOUT)
    finally:
        with _pending_permissions_lock:
            entry = _pending_permissions.pop(permission_id, None)
        _clear_session_permission_tag(permission_id)

    if not signalled or entry is None or entry.get("decision") is None:
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": "No response from SuperIsland within timeout",
                },
            }
        }

    decision = entry["decision"]
    selected = decision.get("selected_option")
    question_text = ""
    first_q = questions[0] if questions else None
    if isinstance(first_q, dict):
        question_text = first_q.get("question") or ""

    if not question_text or selected is None:
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }

    return {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow",
                "updatedInput": {
                    "questions": questions,
                    "answers": {question_text: selected},
                },
            },
        }
    }


def _resolve_permission_request(body):
    permission_id = (body.get("permission_id") or "").strip()
    selected = body.get("selected_option")
    if not permission_id:
        return False, {"error": "missing permission_id"}
    with _pending_permissions_lock:
        entry = _pending_permissions.get(permission_id)
        if not entry:
            return False, {"error": "not found", "permission_id": permission_id}
        entry["decision"] = {"selected_option": selected}
        entry["event"].set()
    return True, {"ok": True, "permission_id": permission_id}


def _pending_permission_for_session(agent, session_id):
    """Shallow view of a session's pending AskUserQuestion prompt, suitable
    for embedding in the /state snapshot. Returns None if nothing is pending."""
    if not session_id:
        return None
    with _pending_permissions_lock:
        for pid, entry in _pending_permissions.items():
            if entry.get("agent") != agent:
                continue
            if entry.get("session_id") != session_id:
                continue
            questions = entry.get("questions") or []
            first = questions[0] if questions else {}
            if not isinstance(first, dict):
                first = {}
            raw_options = first.get("options") or []
            options = []
            for opt in raw_options:
                if isinstance(opt, str):
                    options.append({"label": opt, "value": opt})
                elif isinstance(opt, dict):
                    label = opt.get("label") or opt.get("text") or opt.get("title") or opt.get("value") or ""
                    value = opt.get("value") if opt.get("value") is not None else label
                    options.append({"label": label, "value": value, "description": opt.get("description") or ""})
            return {
                "permission_id": pid,
                "tool_name": entry.get("tool_name"),
                "header": first.get("header") or "",
                "question": first.get("question") or "",
                "options": options,
                "created_at": entry.get("created_at"),
            }
    return None


def _route_get(path):
    path_only, params = _parse_query(path)
    if path_only == "/state":
        return _build_response(200, "OK", _snapshot(_ttl_param(params)))
    if path_only == "/health":
        return _build_response(200, "OK", {"ok": True, "port": PORT, "paused": _paused, "pid": os.getpid()})
    if path_only == "/control/status":
        return _build_response(200, "OK", {"paused": _paused})
    if path_only == "/hooks/status":
        try:
            fn = codex_status if _agent_param(params) == "codex" else cc_status
            return _build_response(200, "OK", fn())
        except Exception as e:
            return _build_response(500, "Internal Error", {"error": str(e)})
    return _build_response(404, "Not Found", {"error": "not found"})


def _route_post(path, body_bytes):
    global _paused
    path_only, params = _parse_query(path)
    if path_only == "/event":
        if _paused:
            return _build_response(503, "Service Unavailable", {"ok": False, "paused": True})
        try:
            data = json.loads(body_bytes.decode("utf-8") or "{}")
        except Exception:
            return _build_response(400, "Bad Request", {"error": "invalid JSON"})
        ok, payload = _apply_event(data)
        return _build_response(200 if ok else 400, "OK" if ok else "Bad Request", payload)
    if path_only == "/focus":
        try:
            data = json.loads(body_bytes.decode("utf-8") or "{}")
        except Exception:
            return _build_response(400, "Bad Request", {"error": "invalid JSON"})
        ok, payload = _focus_session_request(data)
        if ok:
            return _build_response(200, "OK", payload)
        code = 404 if payload.get("error") == "session not found" else 500
        reason = "Not Found" if code == 404 else "Internal Error"
        return _build_response(code, reason, payload)
    if path_only == "/control/pause":
        _paused = True
        return _build_response(200, "OK", {"ok": True, "paused": True})
    if path_only == "/control/resume":
        _paused = False
        return _build_response(200, "OK", {"ok": True, "paused": False})
    if path_only == "/hooks/install":
        try:
            agent = _agent_param(params)
            events = codex_install() if agent == "codex" else cc_install()
            return _build_response(200, "OK", {"ok": True, "agent": agent, "events": events})
        except Exception as e:
            return _build_response(500, "Internal Error", {"error": str(e)})
    if path_only == "/hooks/uninstall":
        try:
            agent = _agent_param(params)
            events = codex_uninstall() if agent == "codex" else cc_uninstall()
            return _build_response(200, "OK", {"ok": True, "agent": agent, "removed": events})
        except Exception as e:
            return _build_response(500, "Internal Error", {"error": str(e)})
    if path_only == "/sound":
        tone = (params.get("tone") or "").strip().lower()
        played = _play_alert_sound(tone)
        if played is None:
            return _build_response(400, "Bad Request", {"error": "unknown tone", "got": tone})
        return _build_response(200, "OK", {"ok": played, "tone": tone})
    if path_only == "/hooks/permission":
        try:
            data = json.loads(body_bytes.decode("utf-8") or "{}")
        except Exception:
            data = {}
        response = _handle_permission_hook(data)
        return _build_response(200, "OK", response)
    if path_only == "/permission/resolve":
        try:
            data = json.loads(body_bytes.decode("utf-8") or "{}")
        except Exception:
            return _build_response(400, "Bad Request", {"error": "invalid JSON"})
        ok, payload = _resolve_permission_request(data)
        if ok:
            return _build_response(200, "OK", payload)
        code = 404 if payload.get("error") == "not found" else 400
        reason = "Not Found" if code == 404 else "Bad Request"
        return _build_response(code, reason, payload)
    return _build_response(404, "Not Found", {"error": "not found"})


def _handle_client(conn):
    try:
        conn.settimeout(3.0)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
            if len(buf) > 64 * 1024:
                conn.sendall(_build_response(431, "Request Header Fields Too Large", {"error": "headers too large"}))
                return

        header_end = buf.index(b"\r\n\r\n")
        header_part = buf[:header_end].decode("iso-8859-1", errors="replace")
        body_start = buf[header_end + 4:]

        lines = header_part.split("\r\n")
        if not lines:
            return
        try:
            method, path, _proto = lines[0].split(" ", 2)
        except ValueError:
            return

        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        content_length = int(headers.get("content-length", "0") or "0")
        body = body_start
        while len(body) < content_length:
            chunk = conn.recv(min(4096, content_length - len(body)))
            if not chunk:
                break
            body += chunk

        if method == "GET":
            resp = _route_get(path)
        elif method == "POST":
            resp = _route_post(path, body)
        elif method == "OPTIONS":
            resp = _build_response(204, "No Content", {})
        else:
            resp = _build_response(405, "Method Not Allowed", {"error": "method not allowed"})

        conn.sendall(resp)
    except socket.timeout:
        return
    except Exception as e:
        sys.stderr.write(f"handler error: {e}\n")
        sys.stderr.flush()
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(16)
    sys.stderr.write(
        f"agents-status bridge on 127.0.0.1:{PORT} "
        f"(claude_hook={CC_HOOK_SCRIPT or 'unset'} codex_hook={CODEX_HOOK_SCRIPT or 'unset'})\n"
    )
    sys.stderr.flush()
    while True:
        conn, _addr = srv.accept()
        t = threading.Thread(target=_handle_client, args=(conn,), daemon=True)
        t.start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
