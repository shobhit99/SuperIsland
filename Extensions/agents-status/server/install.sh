#!/bin/bash
# Install the agents-status bridge as a launchd user agent.
# After one-time run, the server starts at login and can be fully controlled
# from the Agents Status extension's settings UI.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXT_ROOT="$(cd "$HERE/.." && pwd)"
LABEL="com.superisland.agents-status"
LEGACY_LABEL="com.superisland.cc-status"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist"
GUI_DOMAIN="gui/$(id -u)"
PY="$(command -v python3 || echo /usr/bin/python3)"
# Always point hooks at the deployed copy under Application Support, not the
# dev checkout install.sh may have been run from. SuperIsland loads the
# extension from this canonical path, so the hook script lives there too.
INSTALLED_EXT_ROOT="$HOME/Library/Application Support/SuperIsland/Extensions/agents-status"
CC_HOOK_SCRIPT="$INSTALLED_EXT_ROOT/hooks/cc-event-hook.sh"
CODEX_HOOK_SCRIPT="$INSTALLED_EXT_ROOT/hooks/codex-notify-hook.sh"
LOG_DIR="$HOME/Library/Logs/SuperIsland"

mkdir -p "$LOG_DIR"
chmod +x "$CC_HOOK_SCRIPT" "$CODEX_HOOK_SCRIPT" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PY}</string>
    <string>${HERE}/server.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/agents-status.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/agents-status.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AGENTS_STATUS_PORT</key><string>7823</string>
    <key>AGENTS_STATUS_WORKING_TIMEOUT</key><string>30</string>
    <key>AGENTS_STATUS_CC_HOOK_SCRIPT</key><string>${CC_HOOK_SCRIPT}</string>
    <key>AGENTS_STATUS_CODEX_HOOK_SCRIPT</key><string>${CODEX_HOOK_SCRIPT}</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "$GUI_DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootout "$GUI_DOMAIN" "$LEGACY_PLIST" 2>/dev/null || true
rm -f "$LEGACY_PLIST"
launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
launchctl kickstart -k "$GUI_DOMAIN/$LABEL" 2>/dev/null || true

sleep 0.3
if curl -fsS http://127.0.0.1:7823/health >/dev/null 2>&1; then
  echo "agents-status bridge installed and running on 127.0.0.1:7823"
  echo "Claude Code hook: $CC_HOOK_SCRIPT"
  echo "Codex hook:       $CODEX_HOOK_SCRIPT"
  echo ""
  echo "Now toggle the agents you want under CLI Hooks in the extension settings."
else
  echo "Installed launchd job, but bridge is not responding yet."
  echo "Check logs: $LOG_DIR/agents-status.err.log"
fi
