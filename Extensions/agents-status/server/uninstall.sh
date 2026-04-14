#!/bin/bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.superisland.agents-status.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm "$PLIST"
  echo "Removed $PLIST"
else
  echo "No plist found at $PLIST"
fi
