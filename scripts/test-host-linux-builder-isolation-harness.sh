#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-host-linux-builder-isolation.sh
source "$ROOT/scripts/lib-host-linux-builder-isolation.sh"

fail() {
  echo "host Linux builder isolation harness failed: $*" >&2
  exit 1
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-linux-builder-isolation.XXXXXX")"
TEST_CONTAINER_NAME=""
TEST_CACHE_ID=""

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$TEST_CONTAINER_NAME" && -n "$TEST_CACHE_ID" ]]; then
    host_linux_builder_stop_container \
      "$TEST_CONTAINER_NAME" "$TEST_CACHE_ID" >/dev/null 2>&1 || true
  fi
  find "$TMP_ROOT" -xdev -depth -mindepth 1 -delete
  rmdir "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

fake_builder() (
  exec 9>"$TMP_ROOT/build.lock"
  /usr/bin/lockf 9
  if [[ -f "$TMP_ROOT/receipt" ]]; then
    printf 'reused\n' >>"$TMP_ROOT/results"
    exit 0
  fi
  if ! mkdir "$TMP_ROOT/active"; then
    : >"$TMP_ROOT/overlap"
    exit 1
  fi
  printf 'built\n' >>"$TMP_ROOT/results"
  sleep 0.25
  : >"$TMP_ROOT/receipt"
  rmdir "$TMP_ROOT/active"
)

fake_builder &
first_builder="$!"
fake_builder &
second_builder="$!"
wait "$first_builder" "$second_builder"
[[ ! -e "$TMP_ROOT/overlap" ]] \
  || fail "two builders overlapped persistent target use"
[[ "$(grep -Fc built "$TMP_ROOT/results")" == "1" \
  && "$(grep -Fc reused "$TMP_ROOT/results")" == "1" ]] \
  || fail "the lock waiter did not re-verify and reuse the completed bundle"

assert_cancelled_waiter_does_not_cleanup() {
  local prefix="$1"
  local container_name="${2:-}"
  local cache_id="${3:-}"
  local lock="$TMP_ROOT/$prefix.lock"
  local holder_ready="$TMP_ROOT/$prefix-holder-ready"
  local cleanup_marker="$TMP_ROOT/$prefix-cleanup"
  local acquired_marker="$TMP_ROOT/$prefix-acquired"
  local monitor_was_enabled=0
  local holder_pid waiter_pid waiter_pgid waiter_status

  (
    trap 'exit 0' TERM
    exec 8>"$lock"
    /usr/bin/lockf 8
    : >"$holder_ready"
    while :; do
      sleep 0.1
    done
  ) &
  holder_pid="$!"
  while [[ ! -f "$holder_ready" ]]; do
    sleep 0.02
  done

  [[ "$-" == *m* ]] && monitor_was_enabled=1
  set -m
  (
    lock_held=0
    trap '
      if [[ "$lock_held" == "1" ]]; then
        : >"$cleanup_marker"
        if [[ -n "$container_name" ]]; then
          host_linux_builder_stop_container "$container_name" "$cache_id"
        fi
      fi
      exit 143
    ' TERM
    exec 9>"$lock"
    /usr/bin/lockf 9
    lock_held=1
    : >"$acquired_marker"
  ) >/dev/null 2>&1 &
  waiter_pid="$!"
  ((monitor_was_enabled)) || set +m
  sleep 0.1
  waiter_pgid="$(
    ps -o pgid= -p "$waiter_pid" | tr -d '[:space:]'
  )"
  [[ "$waiter_pgid" == "$waiter_pid" ]] \
    || fail "cancelled waiter did not receive an isolated process group"
  kill -TERM -- "-$waiter_pgid"
  set +e
  wait "$waiter_pid"
  waiter_status="$?"
  set -e
  [[ "$waiter_status" == "143" ]] \
    || fail "cancelled lock waiter returned $waiter_status instead of 143"
  [[ ! -e "$cleanup_marker" && ! -e "$acquired_marker" ]] \
    || fail "cancelled pre-lock waiter acted as the cache owner"
  if [[ -n "$container_name" ]]; then
    docker container inspect "$container_name" >/dev/null 2>&1 \
      || fail "cancelled pre-lock waiter removed the holder container"
  fi
  kill -TERM "$holder_pid"
  wait "$holder_pid"
}

assert_cancelled_waiter_does_not_cleanup marker-only

if [[ "${NVPN_TEST_HOST_LINUX_BUILDER_DOCKER:-0}" == "1" ]]; then
  command -v docker >/dev/null 2>&1 \
    || fail "real container cleanup test requires Docker"
  TEST_CACHE_ID="$(
    printf '%s' "$TMP_ROOT" | shasum -a 256 | awk '{ print $1 }'
  )"
  TEST_CONTAINER_NAME="nvpn-linux-builder-test-${TEST_CACHE_ID:0:20}"
  image="${NVPN_TEST_HOST_LINUX_BUILDER_IMAGE:-ubuntu:24.04}"
  platform="${NVPN_TEST_HOST_LINUX_BUILDER_PLATFORM:-linux/amd64}"
  docker image inspect "$image" >/dev/null 2>&1 \
    || fail "real container cleanup test requires the cached image $image"
  docker run --detach \
    --platform "$platform" \
    --name "$TEST_CONTAINER_NAME" \
    --network none \
    --label "to.nostrvpn.release-builder=host-linux-vm-bundle" \
    --label "to.nostrvpn.release-builder-cache=$TEST_CACHE_ID" \
    "$image" sleep 120 >/dev/null
  assert_cancelled_waiter_does_not_cleanup \
    real-container "$TEST_CONTAINER_NAME" "$TEST_CACHE_ID"
  ready="$TMP_ROOT/termination-ready"
  (
    trap 'host_linux_builder_stop_container \
      "$TEST_CONTAINER_NAME" "$TEST_CACHE_ID"; exit 143' TERM
    : >"$ready"
    while :; do
      sleep 0.1
    done
  ) &
  cleanup_holder="$!"
  while [[ ! -f "$ready" ]]; do
    sleep 0.02
  done
  terminate_started="$SECONDS"
  kill -TERM "$cleanup_holder"
  set +e
  wait "$cleanup_holder"
  cleanup_status="$?"
  set -e
  [[ "$cleanup_status" == "143" ]] \
    || fail "TERM cleanup returned $cleanup_status instead of 143"
  (( SECONDS - terminate_started < 2 )) \
    || fail "TERM cleanup exceeded the release-gate cancellation grace"
  ! docker container inspect "$TEST_CONTAINER_NAME" >/dev/null 2>&1 \
    || fail "daemon-side container survived TERM cleanup"

  # Model a SIGKILL: no trap runs, but the next lock holder sees the same
  # deterministic name and removes the exactly labeled daemon-side survivor.
  docker run --detach \
    --platform "$platform" \
    --name "$TEST_CONTAINER_NAME" \
    --network none \
    --label "to.nostrvpn.release-builder=host-linux-vm-bundle" \
    --label "to.nostrvpn.release-builder-cache=$TEST_CACHE_ID" \
    "$image" sleep 120 >/dev/null
  host_linux_builder_stop_container \
    "$TEST_CONTAINER_NAME" "$TEST_CACHE_ID"
  ! docker container inspect "$TEST_CONTAINER_NAME" >/dev/null 2>&1 \
    || fail "validated daemon-side container survived cleanup"
  TEST_CONTAINER_NAME=""
  TEST_CACHE_ID=""
fi

echo "host Linux builder isolation harness passed"
