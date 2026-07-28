#!/usr/bin/env bash

# Return live PID/start-time records whose resolved executable exactly matches
# the imported release-gate app. Command-line mentions are intentionally
# ignored, and start time prevents later signals from hitting a reused PID.
linux_exact_executable_records() {
  local executable="$1" expected proc actual stat rest state start_time
  expected="$(readlink -f -- "$executable")" || return 1
  for proc in /proc/[0-9]*; do
    [[ -L "$proc/exe" ]] || continue
    actual="$(readlink -f -- "$proc/exe" 2>/dev/null)" || continue
    [[ "$actual" == "$expected" ]] || continue
    IFS= read -r stat <"$proc/stat" 2>/dev/null || continue
    rest="${stat##*) }"
    set -- $rest
    state="${1:-}"
    start_time="${20:-}"
    [[ -n "$state" && -n "$start_time" ]] || continue
    [[ "$state" != "Z" && "$state" != "X" ]] || continue
    printf '%s\t%s\n' "${proc##*/}" "$start_time"
  done
}

linux_exact_executable_pids() {
  local executable="$1" records pid _
  records="$(linux_exact_executable_records "$executable")" || return 1
  while IFS=$'\t' read -r pid _; do
    [[ -n "$pid" ]] && printf '%s\n' "$pid"
  done <<<"$records"
}

linux_signal_exact_executable() {
  local executable="$1" pid="$2" start_time="$3" signal="$4"
  local expected proc actual stat rest current_start
  expected="$(readlink -f -- "$executable")" || return 1
  proc="/proc/$pid"
  actual="$(readlink -f -- "$proc/exe" 2>/dev/null)" || return 0
  [[ "$actual" == "$expected" ]] || return 0
  IFS= read -r stat <"$proc/stat" 2>/dev/null || return 0
  rest="${stat##*) }"
  set -- $rest
  current_start="${20:-}"
  [[ -n "$current_start" && "$current_start" == "$start_time" ]] || return 0
  kill -s "$signal" -- "$pid" 2>/dev/null || {
    actual="$(readlink -f -- "$proc/exe" 2>/dev/null)" || return 0
    [[ "$actual" != "$expected" ]] && return 0
    return 1
  }
}

linux_stop_exact_test_app() {
  local executable="$1" records pid start_time deadline
  records="$(linux_exact_executable_records "$executable")" || return 1
  [[ -n "$records" ]] || return 0

  while IFS=$'\t' read -r pid start_time; do
    [[ -n "$pid" ]] || continue
    linux_signal_exact_executable \
      "$executable" "$pid" "$start_time" TERM || return 1
  done <<<"$records"

  deadline=$((SECONDS + 3))
  while ((SECONDS < deadline)); do
    records="$(linux_exact_executable_records "$executable")" || return 1
    [[ -z "$records" ]] && return 0
    sleep 0.1
  done

  while IFS=$'\t' read -r pid start_time; do
    [[ -n "$pid" ]] || continue
    linux_signal_exact_executable \
      "$executable" "$pid" "$start_time" KILL || return 1
  done <<<"$records"

  deadline=$((SECONDS + 3))
  while ((SECONDS < deadline)); do
    records="$(linux_exact_executable_records "$executable")" || return 1
    [[ -z "$records" ]] && return 0
    sleep 0.1
  done
  return 1
}
