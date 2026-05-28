#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_NAME="${SESSION_NAME:-notchcopilot-live-reload}"
WATCH_LOG="${WATCH_LOG:-$ROOT_DIR/build/live-reload.watch.log}"
BUILD_LOG="${BUILD_LOG:-$ROOT_DIR/build/live-reload.log}"
LEGACY_LABEL="${LEGACY_LABEL:-com.notchcopilot.dev-live-reload}"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

if ! command -v screen >/dev/null 2>&1; then
  echo "screen is required for detached live reload on macOS." >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/build"

# Clean up the older LaunchAgent path if it was installed. LaunchAgents started
# directly from Desktop-protected folders can be blocked by macOS TCC.
launchctl bootout "gui/$(id -u)" "$LEGACY_PLIST" >/dev/null 2>&1 || true
launchctl remove "$LEGACY_LABEL" >/dev/null 2>&1 || true
rm -f "$LEGACY_PLIST"

screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1 || true

ROOT_QUOTED="$(printf "%q" "$ROOT_DIR")"
WATCH_LOG_QUOTED="$(printf "%q" "$WATCH_LOG")"

screen -dmS "$SESSION_NAME" /bin/zsh -lc "cd $ROOT_QUOTED && exec ./Tools/dev-live-reload.sh >> $WATCH_LOG_QUOTED 2>&1"

sleep 1

echo "Started live reload screen session: $SESSION_NAME"
echo "Watcher log: $WATCH_LOG"
echo "Build log: $BUILD_LOG"
screen -list | grep "$SESSION_NAME" || true
