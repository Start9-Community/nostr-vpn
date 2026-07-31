#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/lib-mobile-ios-release-network.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-runner-harness.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() {
  echo "iOS Release runner harness failed: $*" >&2
  exit 1
}

# shellcheck disable=SC1090
source "$RUNNER"
NVPN_IOS_XCTEST_TERM_GRACE_SECS=1

run_bounded() {
  local name="$1" timeout="$2" launch_timeout="$3" marker="$4"
  shift 4
  ios_release_network_run_bounded_xcode \
    "$name" "$timeout" "$launch_timeout" "$marker" \
    "$TEMP_ROOT/$name.log" "$TEMP_ROOT/$name-markers.tsv" "" "" \
    "$@"
}

run_bounded success 5 2 FIRST \
  bash -c 'printf "FIRST\nordinary output\n"'
grep -Fxq FIRST "$TEMP_ROOT/success.log" \
  || fail "bounded runner did not retain command output"

set +e
run_bounded missing-marker 5 2 NEVER \
  bash -c 'printf "ordinary failure\n"; exit 7'
missing_status=$?
run_bounded launch-timeout 5 1 FIRST \
  bash -c 'sleep 10'
launch_status=$?
run_bounded total-timeout 1 5 FIRST \
  bash -c 'trap "" TERM; printf "FIRST\n"; (trap "" TERM; sleep 10) & wait'
total_status=$?
set -e
[[ "$missing_status" -eq 125 ]] \
  || fail "missing first marker returned $missing_status instead of 125"
[[ "$launch_status" -eq 125 ]] \
  || fail "launch timeout returned $launch_status instead of 125"
[[ "$total_status" -eq 124 ]] \
  || fail "total timeout returned $total_status instead of 124"
if ps -axo command= | grep -F 'sleep 10' | grep -v grep >/dev/null; then
  fail "bounded runner left its fixture child running"
fi

spec="$(
  python3 - <<'PY'
import base64
import json

payload = {
    "wireGuardConfig": (
        "[Interface]\n"
        "PrivateKey = fake-private-key-material\n"
        "[Peer]\n"
    )
}
print(base64.b64encode(json.dumps(payload).encode()).decode())
PY
)"
private_log="$TEMP_ROOT/private.log"
private_result="$TEMP_ROOT/private.xcresult"
private_summary="$TEMP_ROOT/private-xcresult-summary.json"
private_redaction="$TEMP_ROOT/private-diagnostic-redaction.json"
printf '%s\nfake-private-key-material\n' "$spec" >"$private_log"
mkdir -p "$private_result/Data"
printf '%s\n' "$spec" >"$private_result/Data/private"
IOS_RELEASE_NETWORK_CASE_XCTESTRUN="$TEMP_ROOT/private.xctestrun"
printf '%s\n' "$spec" >"$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
ios_release_network_delete_private_test_products
[[ ! -e "$TEMP_ROOT/private.xctestrun" ]] \
  || fail "private xctestrun survived cleanup"
[[ -e "$private_log" && -d "$private_result" ]] \
  || fail "evidence was deleted with the private xctestrun"
ios_release_network_preserve_diagnostics \
  "$spec" "$private_log" "$private_result"
[[ ! -e "$private_result" ]] \
  || fail "unsafe xcresult was retained instead of redacted to its summary"
grep -Fq '<redacted-private-gate-input>' "$private_log" \
  || fail "private xcode log was not redacted"
python3 - "$private_redaction" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if payload.get("logRedacted") is not True:
    raise SystemExit("redaction receipt did not record log redaction")
if payload.get("xcresultRedactedToSummary") is not True:
    raise SystemExit("redaction receipt did not record xcresult redaction")
if payload.get("retainedFullXcresult") is not False:
    raise SystemExit("redaction receipt claims unsafe xcresult retention")
PY
ios_release_network_assert_retained_no_secrets \
  "$spec" "$private_log" "$private_summary" "$private_redaction"

visual_result="$TEMP_ROOT/visual-only.xcresult"
visual_log="$TEMP_ROOT/visual-only.log"
visual_redaction="$TEMP_ROOT/visual-only-diagnostic-redaction.json"
printf '%s\n' 'ordinary xcode output' >"$visual_log"
mkdir -p "$visual_result/Data"
printf '%s\n' 'rendered screenshot bytes without searchable input text' \
  >"$visual_result/Data/screenshot"
ios_release_network_preserve_diagnostics \
  "$spec" "$visual_log" "$visual_result"
[[ ! -e "$visual_result" ]] \
  || fail "WireGuard UI xcresult was retained despite visual secret exposure"
python3 - "$visual_redaction" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if payload.get("privateVisualInputForcedSummaryOnly") is not True:
    raise SystemExit("redaction receipt omitted the visual-input policy")
if payload.get("retainedFullXcresult") is not False:
    raise SystemExit("redaction receipt claims WireGuard UI xcresult retention")
PY

pending_log="$TEMP_ROOT/interrupted.log"
pending_result="$TEMP_ROOT/interrupted.xcresult"
printf '%s\n' "$spec" >"$pending_log"
mkdir -p "$pending_result"
printf '%s\n' "$spec" >"$pending_result/private"
ios_release_network_register_diagnostics \
  "$spec" "$pending_log" "$pending_result"
ios_release_network_abort_active_run
[[ ! -e "$pending_log" && ! -e "$pending_result" ]] \
  || fail "interrupt cleanup retained unredacted diagnostics"

timeout_signing="$(
  mktemp -d "$TEMP_ROOT/nvpn-ios-release-signing.XXXXXX"
)"
IOS_RELEASE_NETWORK_PREPARED=1
IOS_RELEASE_NETWORK_SIGNING_DIR="$timeout_signing"
IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE="$timeout_signing/active-xcode.pgid"
IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64=""
NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR="$TEMP_ROOT/timeout-artifacts"
NVPN_IOS_DISCONNECT_CLEANUP_TOTAL_TIMEOUT_SECS=1
ios_release_network_disconnect_cleanup_inner() {
  trap "" TERM
  (trap "" TERM; sleep 10) &
  wait
}
set +e
ios_release_network_disconnect_cleanup
cleanup_status=$?
set -e
[[ "$cleanup_status" -ne 0 ]] \
  || fail "end-to-end disconnect cleanup deadline passed a hung cleanup"
[[ ! -e "$timeout_signing" ]] \
  || fail "timed-out disconnect cleanup retained private signing state"
if ps -axo command= | grep -F 'sleep 10' | grep -v grep >/dev/null; then
  fail "disconnect cleanup deadline left its fixture child running"
fi

for token in \
  'IOS_RELEASE_NETWORK_DESTINATION="platform=iOS,id=$device_udid,arch=arm64"' \
  '-parallel-testing-enabled NO' \
  'appSigningClass": "distribution"' \
  'runnerSigningClass": "development"' \
  'ios_release_network_write_runner_diagnostics' \
  'ios_release_network_preserve_diagnostics' \
  'NVPN_IOS_XCTEST_LAUNCH_TIMEOUT_SECS' \
  'NVPN_IOS_XCTEST_CLEANUP_TIMEOUT_SECS' \
  'NVPN_IOS_DISCONNECT_CLEANUP_TOTAL_TIMEOUT_SECS'
do
  grep -Fq -- "$token" "$RUNNER" \
    || fail "runner contract lacks: $token"
done
if sed -n '/ios_release_network_test_command()/,/^}/p' "$RUNNER" \
  | grep -Fq -- '-quiet'
then
  fail "physical xcodebuild runner still hides exact launch diagnostics"
fi
diagnostics="$(
  sed -n \
    '/ios_release_network_write_runner_diagnostics()/,/^}/p' "$RUNNER"
)"
grep -Fq '"testBundleHostedByDebuggableRunner": true' <<<"$diagnostics" \
  || fail "iOS runner receipt does not describe the hosted test bundle"
if grep -Eq 'test_entitlements|"testBundleDebuggable": true' <<<"$diagnostics"; then
  fail "nested iOS test bundle still requires a debug entitlement"
fi

echo "MOBILE_IOS_RELEASE_RUNNER_HARNESS_OK"
