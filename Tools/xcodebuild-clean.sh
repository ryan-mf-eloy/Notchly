#!/usr/bin/env bash
set -o pipefail

raw_log="${XCODEBUILD_CLEAN_RAW_LOG:-$(mktemp "${TMPDIR:-/tmp}/notchly-xcodebuild.XXXXXX.log")}"

xcodebuild "$@" 2>&1 | tee "$raw_log" | sed -E \
  -e '/^[0-9-]+ [0-9:.]+ xcodebuild\[[0-9]+:[0-9]+\] \[MT\] IDELaunchParametersSnapshot: The operation couldn.t be completed\. \(DebuggerLLDB\.DebuggerVersionStore\.StoreError error 0\.\)$/d' \
  -e '/^[0-9-]+ [0-9:.]+ xcodebuild\[[0-9]+:[0-9]+\] \[MT\] IDELaunchParametersSnapshot: no debugger version$/d' \
  -e '/^[0-9-]+ [0-9:.]+ xcodebuild\[[0-9]+:[0-9]+\] \[MT\] IDETestOperationsObserverDebug: /d'
status=${PIPESTATUS[0]}

if [[ "$status" -ne 0 ]]; then
  printf 'Raw xcodebuild log: %s\n' "$raw_log" >&2
fi

exit "$status"
