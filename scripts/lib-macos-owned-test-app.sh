#!/usr/bin/env bash

# Return only processes whose executable path exactly matches the imported
# release-gate app. `-ww` prevents macOS ps from truncating long bundle paths.
macos_exact_executable_pids() {
  local executable="$1"
  ps -ww -axo pid=,comm= | python3 -c '
import sys

target = sys.argv[1]
for line in sys.stdin:
    fields = line.lstrip().split(maxsplit=1)
    if len(fields) == 2 and fields[1].rstrip("\n") == target:
        print(fields[0])
' "$executable"
}

macos_stop_exact_test_app() {
  local executable="$1"
  local pids pid deadline
  pids="$(macos_exact_executable_pids "$executable")"
  [[ -n "$pids" ]] || return 0

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done <<<"$pids"

  deadline=$((SECONDS + 3))
  while ((SECONDS < deadline)); do
    pids="$(macos_exact_executable_pids "$executable")"
    [[ -z "$pids" ]] && return 0
    sleep 0.1
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" >/dev/null 2>&1 || true
  done <<<"$pids"
  [[ -z "$(macos_exact_executable_pids "$executable")" ]]
}
