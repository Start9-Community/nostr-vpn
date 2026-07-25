#!/usr/bin/env bash

# Small Bash 3-compatible lane runner for release-gate work that is genuinely
# resource-isolated. Callers remain responsible for keeping measurements and
# shared devices out of concurrent lanes.

RELEASE_GATE_PARALLEL_PIDS=()
RELEASE_GATE_PARALLEL_LABELS=()
RELEASE_GATE_PARALLEL_LOGS=()
RELEASE_GATE_PARALLEL_STARTED_AT=()
RELEASE_GATE_PARALLEL_LAST_INDEX=""
RELEASE_GATE_PARALLEL_LOG_DIR=""

release_gate_parallel_init() {
  RELEASE_GATE_PARALLEL_LOG_DIR="$1"
  mkdir -p "$RELEASE_GATE_PARALLEL_LOG_DIR"
}

release_gate_parallel_log_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

release_gate_parallel_start() {
  local label="$1"
  shift
  if (($# == 0)); then
    printf 'release gate parallel lane failed: missing command for %s\n' "$label" >&2
    return 2
  fi
  if [[ -z "$RELEASE_GATE_PARALLEL_LOG_DIR" ]]; then
    printf 'release gate parallel lane failed: runner was not initialized\n' >&2
    return 2
  fi

  local index="${#RELEASE_GATE_PARALLEL_PIDS[@]}"
  local log_name log_path
  log_name="$(release_gate_parallel_log_name "$label")"
  log_path="$RELEASE_GATE_PARALLEL_LOG_DIR/${log_name:-lane}-$index.log"
  (
    set -euo pipefail
    "$@"
  ) >"$log_path" 2>&1 &

  RELEASE_GATE_PARALLEL_PIDS[$index]=$!
  RELEASE_GATE_PARALLEL_LABELS[$index]="$label"
  RELEASE_GATE_PARALLEL_LOGS[$index]="$log_path"
  RELEASE_GATE_PARALLEL_STARTED_AT[$index]="$(date +%s)"
  RELEASE_GATE_PARALLEL_LAST_INDEX="$index"
  printf 'Started release-gate lane: %s (log: %s)\n' "$label" "$log_path"
}

release_gate_parallel_kill_tree() {
  local pid="$1"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    release_gate_parallel_kill_tree "$child"
  done
  kill "$pid" >/dev/null 2>&1 || true
}

release_gate_parallel_cancel_all() {
  local index pid
  for index in "${!RELEASE_GATE_PARALLEL_PIDS[@]}"; do
    pid="${RELEASE_GATE_PARALLEL_PIDS[$index]:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      release_gate_parallel_kill_tree "$pid"
    fi
  done
  for index in "${!RELEASE_GATE_PARALLEL_PIDS[@]}"; do
    pid="${RELEASE_GATE_PARALLEL_PIDS[$index]:-}"
    if [[ -n "$pid" ]]; then
      wait "$pid" >/dev/null 2>&1 || true
      RELEASE_GATE_PARALLEL_PIDS[$index]=""
    fi
  done
}

release_gate_parallel_wait() {
  local index="$1"
  local pid="${RELEASE_GATE_PARALLEL_PIDS[$index]:-}"
  local label="${RELEASE_GATE_PARALLEL_LABELS[$index]:-lane-$index}"
  local log_path="${RELEASE_GATE_PARALLEL_LOGS[$index]:-}"
  local started_at="${RELEASE_GATE_PARALLEL_STARTED_AT[$index]:-$(date +%s)}"
  if [[ -z "$pid" ]]; then
    printf 'release gate parallel lane failed: unknown or completed lane %s\n' "$index" >&2
    return 2
  fi

  local status=0
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  RELEASE_GATE_PARALLEL_PIDS[$index]=""

  local duration=$(( $(date +%s) - started_at ))
  printf '\n===== release-gate lane: %s (%ss) =====\n' "$label" "$duration"
  if [[ -n "$log_path" && -f "$log_path" ]]; then
    cat "$log_path"
  fi
  printf '===== end release-gate lane: %s =====\n\n' "$label"

  if ((status != 0)); then
    printf 'Release-gate lane failed: %s (exit %s, log: %s)\n' \
      "$label" "$status" "$log_path" >&2
    release_gate_parallel_cancel_all
    return "$status"
  fi
  printf 'Release-gate lane passed: %s in %ss\n' "$label" "$duration"
}

release_gate_parallel_wait_group() {
  local remaining=("$@")
  if ((${#remaining[@]} == 0)); then
    return 0
  fi

  # Bash 3 has no `wait -n`. Poll only the lane wrapper PIDs, then reap and
  # report each lane as soon as it finishes. This prevents an early failure in
  # a later-started lane from sitting unnoticed behind a slow first lane.
  while ((${#remaining[@]})); do
    local pending=()
    local index pid status
    for index in "${remaining[@]}"; do
      pid="${RELEASE_GATE_PARALLEL_PIDS[$index]:-}"
      if [[ -z "$pid" ]]; then
        release_gate_parallel_wait "$index"
        return $?
      fi
      if kill -0 "$pid" >/dev/null 2>&1; then
        pending+=("$index")
        continue
      fi
      if release_gate_parallel_wait "$index"; then
        :
      else
        status=$?
        return "$status"
      fi
    done
    remaining=("${pending[@]}")
    if ((${#remaining[@]})); then
      sleep 0.1
    fi
  done
}
