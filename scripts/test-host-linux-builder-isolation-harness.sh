#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-host-linux-builder-isolation.sh
source "$ROOT/scripts/lib-host-linux-builder-isolation.sh"

fail() {
  echo "host Linux builder isolation harness failed: $*" >&2
  exit 1
}

acquire_test_lock() {
  case "$(uname -s)" in
    Darwin) /usr/bin/lockf "$1" ;;
    Linux) flock "$1" ;;
    *) fail "unsupported lock platform: $(uname -s)" ;;
  esac
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-linux-builder-isolation.XXXXXX")"
TEST_CONTAINER_NAME=""
TEST_CACHE_ID=""
TEST_VOLUME_NAME=""
TEST_VOLUME_GENERATION=""

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$TEST_CONTAINER_NAME" && -n "$TEST_CACHE_ID" ]]; then
    host_linux_builder_stop_container \
      "$TEST_CONTAINER_NAME" "$TEST_CACHE_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEST_VOLUME_NAME" \
    && -n "$TEST_CACHE_ID" \
    && -n "$TEST_VOLUME_GENERATION" ]] \
    && host_linux_builder_target_volume_matches \
      "$TEST_VOLUME_NAME" "$TEST_CACHE_ID" "$TEST_VOLUME_GENERATION"
  then
    docker volume rm "$TEST_VOLUME_NAME" >/dev/null 2>&1 || true
  fi
  find "$TMP_ROOT" -xdev -depth -mindepth 1 -delete
  rmdir "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

fake_builder() (
  exec 9>"$TMP_ROOT/build.lock"
  acquire_test_lock 9
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
    acquire_test_lock 8
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
    acquire_test_lock 9
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
  TEST_VOLUME_NAME="nvpn-linux-target-test-${TEST_CACHE_ID:0:20}"
  TEST_VOLUME_GENERATION="test-v3"
  image="${NVPN_TEST_HOST_LINUX_BUILDER_IMAGE:-ubuntu:24.04}"
  platform="${NVPN_TEST_HOST_LINUX_BUILDER_PLATFORM:-linux/amd64}"
  docker image inspect "$image" >/dev/null 2>&1 \
    || fail "real container cleanup test requires the cached image $image"
  host_linux_builder_create_fresh_target_volume \
    "$TEST_VOLUME_NAME" "$TEST_CACHE_ID" "$TEST_VOLUME_GENERATION"
  if host_linux_builder_create_fresh_target_volume \
    "$TEST_VOLUME_NAME" "$TEST_CACHE_ID" wrong-generation \
    >/dev/null 2>&1
  then
    fail "mismatched persistent target volume was accepted"
  fi
  docker run --rm \
    --platform "$platform" \
    --network none \
    --volume "$TEST_VOLUME_NAME:/target" \
    "$image" sh -c 'printf native-volume > /target/probe'
  host_linux_builder_create_fresh_target_volume \
    "$TEST_VOLUME_NAME" "$TEST_CACHE_ID" "$TEST_VOLUME_GENERATION"
  docker run --rm \
    --platform "$platform" \
    --network none \
    --volume "$TEST_VOLUME_NAME:/target" \
    "$image" test ! -e /target/probe \
    || fail "fresh target volume retained a forged compiler output"
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
  host_linux_builder_remove_target_volume \
    "$TEST_VOLUME_NAME" "$TEST_CACHE_ID" "$TEST_VOLUME_GENERATION"
  TEST_VOLUME_NAME=""
  TEST_VOLUME_GENERATION=""
  TEST_CACHE_ID=""
fi

echo "host Linux builder isolation harness passed"
