#!/bin/zsh

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-NotchCopilot}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/NotchCopilotLiveReload}"
APP_NAME="${APP_NAME:-Notchly}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-1}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-0.6}"
LIVE_RELOAD_DIR="${LIVE_RELOAD_DIR:-${TMPDIR:-/tmp}/notchcopilot-live-reload}"
BUILD_LOG="${BUILD_LOG:-$LIVE_RELOAD_DIR/live-reload.log}"
STATE_FILE="${STATE_FILE:-$LIVE_RELOAD_DIR/live-reload.state}"

WATCH_PATHS=(
  "$ROOT_DIR/NotchCopilot"
  "$ROOT_DIR/NotchCopilotTests"
  "$ROOT_DIR/NotchCopilot.xcodeproj"
  "$ROOT_DIR/project.yml"
  "$ROOT_DIR/Config.example.json"
)

timestamp() {
  date "+%H:%M:%S"
}

snapshot() {
  find "${WATCH_PATHS[@]}" \
    \( -path "$ROOT_DIR/build" -o -path "$ROOT_DIR/build/*" \) -prune -o \
    \( -name ".DS_Store" -o -name "*.xcuserstate" -o -name "*.swp" \) -prune -o \
    -type f \
    \( -name "*.swift" \
      -o -name "*.plist" \
      -o -name "*.json" \
      -o -name "*.yml" \
      -o -name "*.yaml" \
      -o -name "*.xcconfig" \
      -o -name "*.entitlements" \
      -o -name "*.xcscheme" \
      -o -name "*.pbxproj" \
      -o -name "*.xcworkspacedata" \
      -o -name "*.strings" \
      -o -name "*.xcassets" \
      -o -name "*.svg" \
      -o -name "*.png" \
      -o -name "*.jpg" \
      -o -name "*.jpeg" \
      -o -name "*.pdf" \) \
    -print0 2>/dev/null \
    | xargs -0 stat -f "%m %z %N" 2>/dev/null \
    | sort
}

changed_files() {
  local previous="$1"
  local current="$2"

  if [[ ! -f "$previous" ]]; then
    sed -E "s/^[0-9]+ [0-9]+ //" "$current" | sed "s#^$ROOT_DIR/##"
    return
  fi

  comm -3 "$previous" "$current" \
    | sed -E "s/^[[:space:]]*[0-9]+ [0-9]+ //" \
    | sed "s#^$ROOT_DIR/##" \
    | sort -u
}

build_and_relaunch() {
  mkdir -p "$(dirname "$BUILD_LOG")"

  echo "[$(timestamp)] Building $SCHEME ($CONFIGURATION)..."
  if xcodebuild \
      -skipMacroValidation \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      build >"$BUILD_LOG" 2>&1; then
    echo "[$(timestamp)] Build OK. Relaunching $APP_NAME..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.4
    open -n "$APP_PATH"
    echo "[$(timestamp)] Live app: $APP_PATH"
  else
    echo "[$(timestamp)] Build failed. Keeping current app open."
    echo "[$(timestamp)] See: $BUILD_LOG"
  fi
}

mkdir -p "$DERIVED_DATA_PATH"
snapshot >"$STATE_FILE"

echo "[$(timestamp)] Watching source changes for $APP_NAME..."
echo "[$(timestamp)] Build log: $BUILD_LOG"

build_and_relaunch

while true; do
  sleep "$POLL_INTERVAL_SECONDS"

  next_state="$(mktemp "${TMPDIR:-/tmp}/notchcopilot-live-reload.XXXXXX")"
  snapshot >"$next_state"

  if ! cmp -s "$STATE_FILE" "$next_state"; then
    changed="$(changed_files "$STATE_FILE" "$next_state")"
    mv "$next_state" "$STATE_FILE"

    echo "[$(timestamp)] Change detected:"
    echo "$changed" | sed "s/^/  - /"

    sleep "$DEBOUNCE_SECONDS"
    snapshot >"$STATE_FILE"
    build_and_relaunch
  else
    rm -f "$next_state"
  fi
done
