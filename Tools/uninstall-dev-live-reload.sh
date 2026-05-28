#!/bin/zsh

set -euo pipefail

SESSION_NAME="${SESSION_NAME:-notchcopilot-live-reload}"
LEGACY_LABEL="${LEGACY_LABEL:-com.notchcopilot.dev-live-reload}"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1 || true

launchctl bootout "gui/$(id -u)" "$LEGACY_PLIST" >/dev/null 2>&1 || true
launchctl remove "$LEGACY_LABEL" >/dev/null 2>&1 || true
rm -f "$LEGACY_PLIST"

echo "Stopped live reload screen session: $SESSION_NAME"
