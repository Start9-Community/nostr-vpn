#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LINUX="$ROOT/tools/run-linux"
E2E_SMOKE="$ROOT/linux/scripts/e2e-smoke.sh"
COMPOSE_FILE="$ROOT/linux/docker-compose.yml"
TIMEOUT_LIB="$ROOT/scripts/lib-release-gate-timeout.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-linux-gui-overlay-harness.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
ROOT_LOCK_SNAPSHOT="$TMP_ROOT/root-Cargo.lock.expected"
LINUX_LOCK_SNAPSHOT="$TMP_ROOT/linux-Cargo.lock.expected"
LOCK_STATUS_SNAPSHOT="$TMP_ROOT/lockfiles.git-status.expected"
FAILURES=0

cp -p "$ROOT/Cargo.lock" "$ROOT_LOCK_SNAPSHOT"
cp -p "$ROOT/linux/Cargo.lock" "$LINUX_LOCK_SNAPSHOT"
git -C "$ROOT" status --porcelain=v1 -- Cargo.lock linux/Cargo.lock \
  >"$LOCK_STATUS_SNAPSHOT"

cleanup() {
  local pid_file pid
  while IFS= read -r pid_file; do
    IFS= read -r pid <"$pid_file" || true
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.05
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(find "$TMP_ROOT" -name 'active-*.pid' -type f 2>/dev/null || true)
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

record_failure() {
  printf 'linux GUI overlay harness failed: %s\n' "$*" >&2
  ((FAILURES += 1))
}

require_source_text() {
  local path="$1" needle="$2" label="$3"
  grep -Fq -- "$needle" "$path" \
    || record_failure "$label"
}

# The container owns all mutable lockfile state. The source checkout remains a
# read-only release input, and non-local builds remain Cargo --locked builds.
require_source_text \
  "$COMPOSE_FILE" \
  '${NVPN_LINUX_ROOT_CARGO_LOCK_PATH:-../Cargo.lock}:/workspace/nostr-vpn/Cargo.lock' \
  "compose does not mount a separate root Cargo.lock overlay"
require_source_text \
  "$COMPOSE_FILE" \
  '${NVPN_LINUX_DESKTOP_CARGO_LOCK_PATH:-./Cargo.lock}:/workspace/nostr-vpn/linux/Cargo.lock' \
  "compose does not mount a separate Linux Cargo.lock overlay"
require_source_text \
  "$E2E_SMOKE" \
  'cargo_lock_args=(--locked)' \
  "Linux GUI smoke does not default Cargo to --locked"
require_source_text \
  "$E2E_SMOKE" \
  'NVPN_LINUX_LOCKFILE_OVERLAY_ACTIVE' \
  "Linux GUI smoke has no local-FIPS overlay marker gate"
require_source_text \
  "$E2E_SMOKE" \
  'cargo_run build "${cargo_lock_args[@]}" -p nvpn' \
  "root Linux GUI Cargo build does not apply the lock policy"
require_source_text \
  "$E2E_SMOKE" \
  'cargo_run build "${cargo_lock_args[@]}" >/dev/null' \
  "desktop Linux GUI Cargo build does not apply the lock policy"
if rg -q 'lock_snapshot_dir|restore_lock_snapshot' "$E2E_SMOKE"; then
  record_failure "Linux GUI smoke still rewrites/restores the shared checkout lockfiles"
fi
require_source_text \
  "$RUN_LINUX" \
  'run_lock_file="${NVPN_LINUX_RUN_LOCK_FILE:-/tmp/nvpn-linux-compose.lock}"' \
  "Linux runner does not use the resource-global advisory lock file"
require_source_text \
  "$RUN_LINUX" \
  'flock -n 9' \
  "Linux runner has no nonblocking Linux advisory-lock path"
require_source_text \
  "$RUN_LINUX" \
  'lockf -t 0 9' \
  "Linux runner has no nonblocking macOS advisory-lock path"
require_source_text \
  "$RUN_LINUX" \
  '9>&-' \
  "Linux runner leaks its advisory-lock descriptor into long-lived children"
if rg -q 'previous_owner|run_lock_dir/owner|recover.*stale' "$RUN_LINUX"; then
  record_failure "Linux runner still uses racy PID/directory stale-lock recovery"
fi
require_source_text \
  "$RUN_LINUX" \
  'NVPN_LINUX_LOCKFILE_OVERLAY_ACTIVE=1' \
  "Linux runner does not mark the isolated in-container execution"

# Refusal happens before any build or filesystem setup.
refusal_log="$TMP_ROOT/refusal.log"
set +e
env -u NVPN_LINUX_LOCKFILE_OVERLAY_ACTIVE \
  NVPN_FIPS_REPO_PATH="$TMP_ROOT/fips" \
  "$E2E_SMOKE" >"$refusal_log" 2>&1
refusal_status=$?
set -e
if ((refusal_status != 2)); then
  record_failure "local-FIPS smoke without an overlay returned $refusal_status, expected 2"
fi
grep -Fq 'requires isolated Cargo.lock overlays' "$refusal_log" \
  || record_failure "local-FIPS smoke did not explain its missing overlay"

make_fake_docker() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${NVPN_TEST_DOCKER_STATE:?}"
mkdir -p "$state"
printf '%q ' "$0" "$@" >>"$state/invocations.log"
printf '\n' >>"$state/invocations.log"

if [[ "${0##*/}" == docker-compose ]]; then
  set -- compose "$@"
fi

stop_active_processes() {
  local pid="" pid_file
  for pid_file in \
    "$state/active-worker.pid" \
    "$state/active-compose-up.pid" \
    "$state/active-readiness.pid"
  do
    [[ -f "$pid_file" ]] || continue
    IFS= read -r pid <"$pid_file" || true
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.01
      done
    fi
  done
}

validate_compose_overlays() {
  local root_overlay="${NVPN_LINUX_ROOT_CARGO_LOCK_PATH:-}"
  local linux_overlay="${NVPN_LINUX_DESKTOP_CARGO_LOCK_PATH:-}"
  local lock_file

  [[ -n "$root_overlay" && -f "$root_overlay" && -w "$root_overlay" ]] \
    || { echo "missing writable root lock overlay" >&2; exit 91; }
  [[ -n "$linux_overlay" && -f "$linux_overlay" && -w "$linux_overlay" ]] \
    || { echo "missing writable Linux lock overlay" >&2; exit 92; }
  [[ "$root_overlay" != "$NVPN_TEST_HOST_ROOT_LOCK" ]] \
    || { echo "root lock overlay aliases the host lock" >&2; exit 93; }
  [[ "$linux_overlay" != "$NVPN_TEST_HOST_LINUX_LOCK" ]] \
    || { echo "Linux lock overlay aliases the host lock" >&2; exit 94; }
  [[ "$root_overlay" != "$linux_overlay" ]] \
    || { echo "root and Linux lock overlays alias each other" >&2; exit 95; }
  cmp -s "$NVPN_TEST_ROOT_LOCK_SNAPSHOT" "$root_overlay" \
    || { echo "root lock overlay does not begin at the exact host bytes" >&2; exit 96; }
  cmp -s "$NVPN_TEST_LINUX_LOCK_SNAPSHOT" "$linux_overlay" \
    || { echo "Linux lock overlay does not begin at the exact host bytes" >&2; exit 97; }

  lock_file="${NVPN_LINUX_RUN_LOCK_FILE:?}"
  [[ -f "$lock_file" && ! -s "$lock_file" ]] \
    || { echo "isolated run has no empty advisory lock file" >&2; exit 98; }
  if (
    exec 8>>"$lock_file"
    if command -v flock >/dev/null 2>&1; then
      flock -n 8 >/dev/null 2>&1
    else
      lockf -t 0 8 >/dev/null 2>&1
    fi
  ); then
    echo "isolated run does not hold its advisory lock" >&2
    exit 99
  fi

  printf '%s\n' "$root_overlay" >"$state/root-overlay.path"
  printf '%s\n' "$linux_overlay" >"$state/linux-overlay.path"
  printf '%s\n' "$lock_file" >"$state/run-lock.path"
  : >"$state/compose-up"
}

block_compose_up() {
  printf '%s\n' "$$" >"$state/active-compose-up.pid"
  printf '%s\n' "$$" >>"$state/all-compose-up.pids"
  : >"$state/compose-up-started"

  compose_up_exit() {
    rm -f "$state/active-compose-up.pid"
  }
  compose_up_signal() {
    : >"$state/compose-up-term-observed"
    exit 143
  }
  trap compose_up_exit EXIT
  trap compose_up_signal HUP INT TERM

  while :; do
    sleep 0.05
  done
}

block_readiness_probe() {
  printf '%s\n' "$$" >"$state/active-readiness.pid"
  printf '%s\n' "$$" >>"$state/all-readiness.pids"
  : >"$state/readiness-started"

  readiness_exit() {
    rm -f "$state/active-readiness.pid"
  }
  readiness_signal() {
    : >"$state/readiness-term-observed"
    exit 143
  }
  trap readiness_exit EXIT
  trap readiness_signal HUP INT TERM

  while :; do
    sleep 0.05
  done
}

run_container_command() {
  local overlay_marker=0 argument
  for argument in "$@"; do
    [[ "$argument" == "NVPN_LINUX_LOCKFILE_OVERLAY_ACTIVE=1" ]] \
      && overlay_marker=1
  done
  ((overlay_marker == 1)) \
    || { echo "container execution lacks the overlay marker" >&2; exit 100; }
  printf '%s\n' "$*" | grep -Fq 'NVPN_FIPS_REPO_PATH=/workspace/fips' \
    || { echo "container execution lost the local FIPS path" >&2; exit 101; }

  root_overlay="$(cat "$state/root-overlay.path")"
  linux_overlay="$(cat "$state/linux-overlay.path")"
  printf '# fake container root resolution\n' >>"$root_overlay"
  printf '# fake container Linux resolution\n' >>"$linux_overlay"

  printf '%s\n' "$$" >"$state/active-worker.pid"
  printf '%s\n' "$$" >>"$state/all-worker.pids"
  : >"$state/container-started"

  worker_exit() {
    rm -f "$state/active-worker.pid"
  }
  worker_signal() {
    : >"$state/container-term-observed"
    exit 143
  }
  trap worker_exit EXIT
  trap worker_signal HUP INT TERM

  case "$NVPN_TEST_DOCKER_MODE" in
    success)
      exit 0
      ;;
    failure)
      exit 37
      ;;
    timeout)
      while :; do
        sleep 0.05
      done
      ;;
    *)
      exit 102
      ;;
  esac
}

case "${1:-}" in
  compose)
    shift
    case "${1:-}" in
      up)
        validate_compose_overlays
        if [[ "$NVPN_TEST_DOCKER_MODE" == compose-timeout ]]; then
          block_compose_up
        fi
        exit 0
        ;;
      kill)
        : >"$state/compose-kill"
        stop_active_processes
        exit 0
        ;;
      down)
        : >"$state/compose-down"
        stop_active_processes
        exit 0
        ;;
      ps|logs)
        exit 0
        ;;
    esac
    ;;
  exec)
    shift
    if printf '%s\n' "$*" | grep -Fq 'test -f /tmp/nostr-vpn-dev-ready'; then
      if [[ "$NVPN_TEST_DOCKER_MODE" == readiness-timeout ]]; then
        block_readiness_probe
      fi
      exit 0
    fi
    run_container_command "$@"
    ;;
  kill|stop|rm)
    stop_active_processes
    exit 0
    ;;
esac

echo "unsupported fake docker invocation: $*" >&2
exit 103
EOF
  chmod +x "$bin/docker"
  ln -s docker "$bin/docker-compose"
}

assert_host_locks_unchanged() {
  local label="$1"
  cmp -s "$ROOT_LOCK_SNAPSHOT" "$ROOT/Cargo.lock" \
    || record_failure "$label mutated the host root Cargo.lock"
  cmp -s "$LINUX_LOCK_SNAPSHOT" "$ROOT/linux/Cargo.lock" \
    || record_failure "$label mutated the host Linux Cargo.lock"
  if ! git -C "$ROOT" status --porcelain=v1 -- Cargo.lock linux/Cargo.lock \
      | cmp -s "$LOCK_STATUS_SNAPSHOT" -
  then
    record_failure "$label changed the tracked host lockfile status"
  fi
}

try_advisory_lock() {
  local lock_file="$1"
  (
    exec 8>>"$lock_file"
    if command -v flock >/dev/null 2>&1; then
      flock -n 8 >/dev/null 2>&1
    elif command -v lockf >/dev/null 2>&1; then
      lockf -t 0 8 >/dev/null 2>&1
    else
      exit 127
    fi
  )
}

assert_lock_released() {
  local lock_file="$1" label="$2" status
  [[ -f "$lock_file" ]] \
    || { record_failure "$label removed its persistent advisory lock file"; return; }
  [[ ! -s "$lock_file" ]] \
    || record_failure "$label wrote mutable ownership state into its advisory lock file"
  set +e
  try_advisory_lock "$lock_file"
  status=$?
  set -e
  if ((status != 0)); then
    record_failure "$label retained its kernel advisory lock after exit"
  fi
}

assert_no_workers() {
  local state="$1" label="$2" pid pid_list
  [[ ! -e "$state/active-worker.pid" ]] \
    || record_failure "$label left an active worker receipt"
  [[ ! -e "$state/active-compose-up.pid" ]] \
    || record_failure "$label left an active Compose startup receipt"
  [[ ! -e "$state/active-readiness.pid" ]] \
    || record_failure "$label left an active readiness-probe receipt"
  for pid_list in \
    "$state/all-worker.pids" \
    "$state/all-compose-up.pids" \
    "$state/all-readiness.pids"
  do
    [[ -f "$pid_list" ]] || continue
    while IFS= read -r pid; do
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
        record_failure "$label left fake Docker process $pid alive"
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done <"$pid_list"
  done
}

assert_case() {
  local mode="$1" timeout_secs="$2" expected_status="$3"
  local case_root="$TMP_ROOT/$mode"
  local bin="$case_root/bin"
  local state="$case_root/state"
  local run_tmp="$case_root/tmp"
  local output="$case_root/output.log"
  local run_lock_file="$run_tmp/nvpn-linux-compose.lock"
  local status root_overlay="" linux_overlay=""

  mkdir -p "$state" "$run_tmp" "$case_root/fips"
  make_fake_docker "$bin"

  set +e
  PATH="$bin:$PATH" \
    TMPDIR="$run_tmp" \
    NVPN_TEST_DOCKER_STATE="$state" \
    NVPN_TEST_DOCKER_MODE="$mode" \
    NVPN_TEST_HOST_ROOT_LOCK="$ROOT/Cargo.lock" \
    NVPN_TEST_HOST_LINUX_LOCK="$ROOT/linux/Cargo.lock" \
    NVPN_TEST_ROOT_LOCK_SNAPSHOT="$ROOT_LOCK_SNAPSHOT" \
    NVPN_TEST_LINUX_LOCK_SNAPSHOT="$LINUX_LOCK_SNAPSHOT" \
    NVPN_LINUX_RUN_LOCK_FILE="$run_lock_file" \
    release_gate_run_with_timeout \
      "Linux GUI overlay $mode" "$timeout_secs" \
      env \
        PATH="$bin:$PATH" \
        TMPDIR="$run_tmp" \
        NVPN_TEST_DOCKER_STATE="$state" \
        NVPN_TEST_DOCKER_MODE="$mode" \
        NVPN_TEST_HOST_ROOT_LOCK="$ROOT/Cargo.lock" \
        NVPN_TEST_HOST_LINUX_LOCK="$ROOT/linux/Cargo.lock" \
        NVPN_TEST_ROOT_LOCK_SNAPSHOT="$ROOT_LOCK_SNAPSHOT" \
        NVPN_TEST_LINUX_LOCK_SNAPSHOT="$LINUX_LOCK_SNAPSHOT" \
        NVPN_LINUX_RUN_LOCK_FILE="$run_lock_file" \
        NVPN_LINUX_NONINTERACTIVE=1 \
        NVPN_LINUX_FIPS_REPO_PATH="$case_root/fips" \
        "$RUN_LINUX" \
        env \
          NVPN_PATCH_LOCAL_FIPS=1 \
          NVPN_FIPS_REPO_PATH=/workspace/fips \
          ./scripts/e2e-smoke.sh \
      >"$output" 2>&1
  status=$?
  set -e

  if ((status != expected_status)); then
    cat "$output" >&2 || true
    record_failure "$mode path returned $status, expected $expected_status"
  fi

  [[ -f "$state/compose-up" ]] \
    || record_failure "$mode path never mounted validated lock overlays"
  if [[ "$mode" == compose-timeout ]]; then
    [[ -f "$state/compose-up-started" ]] \
      || record_failure "Compose-up timeout never entered blocking startup"
    [[ ! -e "$state/container-started" ]] \
      || record_failure "Compose-up timeout incorrectly reached container execution"
  elif [[ "$mode" == readiness-timeout ]]; then
    [[ -f "$state/readiness-started" ]] \
      || record_failure "readiness timeout never entered its blocking probe"
    [[ ! -e "$state/container-started" ]] \
      || record_failure "readiness timeout incorrectly reached container execution"
  else
    [[ -f "$state/container-started" ]] \
      || record_failure "$mode path never started the fake in-container execution"
  fi
  [[ -f "$state/compose-down" ]] \
    || record_failure "$mode path did not remove its isolated compose project"

  if [[ -f "$state/root-overlay.path" ]]; then
    root_overlay="$(cat "$state/root-overlay.path")"
    [[ ! -e "$root_overlay" ]] \
      || record_failure "$mode path retained its root lock overlay"
  fi
  if [[ -f "$state/linux-overlay.path" ]]; then
    linux_overlay="$(cat "$state/linux-overlay.path")"
    [[ ! -e "$linux_overlay" ]] \
      || record_failure "$mode path retained its Linux lock overlay"
  fi
  assert_lock_released "$run_lock_file" "$mode path"

  if [[ "$mode" == timeout ]]; then
    [[ -f "$state/container-term-observed" ]] \
      || record_failure "timeout did not terminate the in-container execution"
  elif [[ "$mode" == compose-timeout ]]; then
    [[ -f "$state/compose-up-term-observed" ]] \
      || record_failure "Compose-up timeout did not terminate foreground startup"
  elif [[ "$mode" == readiness-timeout ]]; then
    [[ -f "$state/readiness-term-observed" ]] \
      || record_failure "readiness timeout did not terminate its Docker probe"
  fi
  if [[ "$mode" == timeout \
    || "$mode" == compose-timeout \
    || "$mode" == readiness-timeout ]]
  then
    [[ -f "$state/compose-kill" ]] \
      || record_failure "timeout did not request container shutdown"
  fi

  if [[ -n "$(find "$run_tmp" -mindepth 1 ! -path "$run_lock_file" -print -quit)" ]]; then
    find "$run_tmp" -mindepth 1 -maxdepth 3 ! -path "$run_lock_file" -print >&2 || true
    record_failure "$mode path left timeout or overlay state in TMPDIR"
  fi

  assert_no_workers "$state" "$mode path"
  assert_host_locks_unchanged "$mode path"
}

assert_global_lock_contention() {
  local case_root="$TMP_ROOT/contention"
  local bin="$case_root/bin"
  local owner_state="$case_root/owner-state"
  local contender_state="$case_root/contender-state"
  local run_tmp="$case_root/tmp"
  local owner_output="$case_root/owner.log"
  local contender_output="$case_root/contender.log"
  local run_lock_file="$run_tmp/nvpn-linux-compose.lock"
  local owner_pid owner_status contender_status worker_pid=""
  local root_overlay="" linux_overlay=""

  mkdir -p "$owner_state" "$contender_state" "$run_tmp" "$case_root/fips"
  make_fake_docker "$bin"

  env \
    PATH="$bin:$PATH" \
    TMPDIR="$run_tmp" \
    NVPN_LINUX_RUN_LOCK_FILE="$run_lock_file" \
    NVPN_TEST_DOCKER_STATE="$owner_state" \
    NVPN_TEST_DOCKER_MODE=timeout \
    NVPN_TEST_HOST_ROOT_LOCK="$ROOT/Cargo.lock" \
    NVPN_TEST_HOST_LINUX_LOCK="$ROOT/linux/Cargo.lock" \
    NVPN_TEST_ROOT_LOCK_SNAPSHOT="$ROOT_LOCK_SNAPSHOT" \
    NVPN_TEST_LINUX_LOCK_SNAPSHOT="$LINUX_LOCK_SNAPSHOT" \
    NVPN_LINUX_NONINTERACTIVE=1 \
    NVPN_LINUX_FIPS_REPO_PATH="$case_root/fips" \
    "$RUN_LINUX" \
      env \
        NVPN_PATCH_LOCAL_FIPS=1 \
        NVPN_FIPS_REPO_PATH=/workspace/fips \
        ./scripts/e2e-smoke.sh \
    >"$owner_output" 2>&1 &
  owner_pid=$!

  for _ in $(seq 1 300); do
    [[ -f "$owner_state/container-started" ]] && break
    kill -0 "$owner_pid" 2>/dev/null || break
    sleep 0.01
  done
  if [[ ! -f "$owner_state/container-started" ]]; then
    cat "$owner_output" >&2 || true
    record_failure "contention owner never reached its isolated container execution"
  fi
  if [[ -f "$owner_state/active-worker.pid" ]]; then
    IFS= read -r worker_pid <"$owner_state/active-worker.pid" || true
  fi
  if [[ ! "$worker_pid" =~ ^[1-9][0-9]*$ ]] \
    || ! kill -0 "$worker_pid" 2>/dev/null
  then
    record_failure "contention owner has no live fake container worker"
  fi
  [[ -f "$run_lock_file" && ! -s "$run_lock_file" ]] \
    || record_failure "contention owner did not create an empty global lock file"
  if try_advisory_lock "$run_lock_file"; then
    record_failure "contention owner did not hold the global kernel lock"
  fi

  # This is intentionally nonisolated and can represent a different checkout:
  # sharing the Compose lock root alone must serialize access to the resource.
  set +e
  env \
    PATH="$bin:$PATH" \
    TMPDIR="$run_tmp" \
    NVPN_LINUX_RUN_LOCK_FILE="$run_lock_file" \
    NVPN_TEST_DOCKER_STATE="$contender_state" \
    NVPN_TEST_DOCKER_MODE=success \
    NVPN_TEST_HOST_ROOT_LOCK="$ROOT/Cargo.lock" \
    NVPN_TEST_HOST_LINUX_LOCK="$ROOT/linux/Cargo.lock" \
    NVPN_TEST_ROOT_LOCK_SNAPSHOT="$ROOT_LOCK_SNAPSHOT" \
    NVPN_TEST_LINUX_LOCK_SNAPSHOT="$LINUX_LOCK_SNAPSHOT" \
    NVPN_LINUX_NONINTERACTIVE=1 \
    "$RUN_LINUX" true \
    >"$contender_output" 2>&1
  contender_status=$?
  set -e

  if ((contender_status != 1)); then
    cat "$contender_output" >&2 || true
    record_failure "nonisolated contender returned $contender_status, expected lock rejection 1"
  fi
  grep -Fq 'Another Linux desktop run owns' "$contender_output" \
    || record_failure "nonisolated contender did not report the global owner"
  [[ ! -e "$contender_state/invocations.log" ]] \
    || record_failure "nonisolated contender reached Docker before lock rejection"
  kill -0 "$owner_pid" 2>/dev/null \
    || record_failure "contender disturbed the owning tools/run-linux process"
  if [[ "$worker_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -0 "$worker_pid" 2>/dev/null \
      || record_failure "contender disturbed the owner's in-container process"
  fi
  [[ ! -e "$owner_state/compose-kill" && ! -e "$owner_state/compose-down" ]] \
    || record_failure "contender triggered teardown of the owner's Compose project"

  kill -TERM "$owner_pid" 2>/dev/null || true
  set +e
  wait "$owner_pid"
  owner_status=$?
  set -e
  if ((owner_status != 143)); then
    cat "$owner_output" >&2 || true
    record_failure "contention owner returned $owner_status after TERM, expected 143"
  fi

  [[ -f "$owner_state/container-term-observed" ]] \
    || record_failure "contention owner did not terminate its container execution"
  [[ -f "$owner_state/compose-down" ]] \
    || record_failure "contention owner did not clean its Compose project"
  if [[ -f "$owner_state/root-overlay.path" ]]; then
    root_overlay="$(cat "$owner_state/root-overlay.path")"
    [[ ! -e "$root_overlay" ]] \
      || record_failure "contention owner retained its root lock overlay"
  fi
  if [[ -f "$owner_state/linux-overlay.path" ]]; then
    linux_overlay="$(cat "$owner_state/linux-overlay.path")"
    [[ ! -e "$linux_overlay" ]] \
      || record_failure "contention owner retained its Linux lock overlay"
  fi
  assert_lock_released "$run_lock_file" "contention owner"
  if [[ -n "$(find "$run_tmp" -mindepth 1 ! -path "$run_lock_file" -print -quit)" ]]; then
    find "$run_tmp" -mindepth 1 -maxdepth 3 ! -path "$run_lock_file" -print >&2 || true
    record_failure "contention case left temporary resource state"
  fi

  assert_no_workers "$owner_state" "contention owner"
  assert_no_workers "$contender_state" "contention contender"
  assert_host_locks_unchanged "global lock contention"
}

# Force the real library's portable watchdog path even on hosts with GNU
# coreutils installed. External run-linux commands still resolve normally.
source "$TIMEOUT_LIB"
command() {
  if [[ "${1:-}" == "-v" \
    && ("${2:-}" == timeout || "${2:-}" == gtimeout) ]]
  then
    return 1
  fi
  builtin command "$@"
}

assert_case success 5 0
assert_case failure 5 37
assert_case timeout 1 124
assert_case compose-timeout 1 124
assert_case readiness-timeout 1 124
assert_global_lock_contention

assert_host_locks_unchanged "complete harness"

if ((FAILURES != 0)); then
  printf 'linux GUI overlay harness: %d assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'linux GUI overlay harness passed\n'
