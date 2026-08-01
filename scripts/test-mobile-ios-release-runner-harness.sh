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
IOS_BUNDLE_ID=fi.siriusbusiness.nvpn

python3 - \
  "$ROOT/scripts/lib-mobile-android-release-gate.sh" \
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh" \
  "$RUNNER" <<'PY'
import pathlib
import re
import sys

temporary_file_contracts = (
    (sys.argv[1], "nvpn-installed-release"),
    (sys.argv[2], "nvpn-release-installed"),
)
for source_path, stem in temporary_file_contracts:
    source = pathlib.Path(source_path).read_text(encoding="utf-8")
    match = re.search(rf'mktemp "([^"\n]*{re.escape(stem)}[^"\n]*)"', source)
    if match is None:
        raise SystemExit(f"missing exact temporary-file contract for {stem}")
    if not match.group(1).endswith("XXXXXX"):
        raise SystemExit(f"BSD mktemp template has a suffix after XXXXXX: {stem}")

ios_source = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
required_ios_fragments = (
    'mktemp -d "$IOS_RELEASE_NETWORK_SIGNING_DIR/NostrVpnIos-$label.XXXXXX"',
    'IOS_RELEASE_NETWORK_CASE_XCTESTRUN="$IOS_RELEASE_NETWORK_CASE_XCTESTRUN_DIR/NostrVpnIos-$label.xctestrun"',
    'rmdir "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN_DIR"',
)
for fragment in required_ios_fragments:
    if fragment not in ios_source:
        raise SystemExit(
            "private XCTest plan does not preserve a real .xctestrun suffix: "
            + fragment
        )
PY
for stem in nvpn-installed-release nvpn-release-installed NostrVpnIos-case.xctestrun; do
  first="$(mktemp "$TEMP_ROOT/$stem.XXXXXX")"
  second="$(mktemp "$TEMP_ROOT/$stem.XXXXXX")"
  [[ "$first" != "$second" && -f "$first" && -f "$second" ]] \
    || fail "two consecutive BSD-style mktemp calls collided for $stem"
  rm -f "$first" "$second"
done

run_bounded() {
  local name="$1" timeout="$2" launch_timeout="$3" marker="$4"
  shift 4
  ios_release_network_run_bounded_xcode \
    "$name" "$timeout" "$launch_timeout" "$marker" "" \
    "$TEMP_ROOT/$name.log" "$TEMP_ROOT/$name-markers.tsv" "" "" \
    "$@"
}

run_bounded success 5 2 FIRST \
  bash -c 'printf "FIRST\nordinary output\n"'
grep -Fxq FIRST "$TEMP_ROOT/success.log" \
  || fail "bounded runner did not retain command output"

device_marker="$TEMP_ROOT/device-marker.log"
printf '%s\n' \
  'NVPN_XCUITEST_RUN_ID=device-marker' \
  'NVPN_XCUITEST_STARTED=1' >"$device_marker"
(
  ios_release_network_copy_runner_markers() {
    cp "$device_marker" "$2"
  }
  ios_release_network_clear_forced_xctrunner() {
    fail "device marker success unexpectedly cleared the XCTest runner"
  }
  ios_release_network_run_bounded_xcode \
    device-marker 5 1 NVPN_XCUITEST_STARTED=1 device-marker \
    "$TEMP_ROOT/device-marker.log.output" \
    "$TEMP_ROOT/device-marker-host-markers.tsv" \
    fixture-device "" \
    bash -c 'printf "Running tests...\n"; sleep 2'
)
grep -Fq 'Running tests...' "$TEMP_ROOT/device-marker.log.output" \
  || fail "device-marker fixture did not retain runner launch output"
if grep -Fq NVPN_XCUITEST_STARTED=1 "$TEMP_ROOT/device-marker.log.output"; then
  fail "device-marker fixture accidentally streamed the first marker"
fi

scoped_cleanup_log="$TEMP_ROOT/scoped-cleanup.log"
stale_device_marker="$TEMP_ROOT/stale-device-marker.log"
printf '%s\n' \
  'NVPN_XCUITEST_RUN_ID=stale-run' \
  'NVPN_XCUITEST_STARTED=1' >"$stale_device_marker"
set +e
(
  ios_release_network_copy_runner_markers() {
    cp "$stale_device_marker" "$2"
  }
  ios_release_network_xctrunner_installed() {
    printf '%s\n' installation-probe >>"$scoped_cleanup_log"
    return 1
  }
  xcrun() {
    printf 'xcrun %s\n' "$*" >>"$scoped_cleanup_log"
  }
  ios_release_network_run_bounded_xcode \
    device-no-marker 5 1 NVPN_XCUITEST_STARTED=1 device-no-marker \
    "$TEMP_ROOT/device-no-marker.log" \
    "$TEMP_ROOT/device-no-marker-host-markers.tsv" \
    fixture-device "" \
    bash -c 'sleep 10'
)
device_no_marker_status=$?
set -e
[[ "$device_no_marker_status" -eq 125 ]] \
  || fail "device no-marker timeout returned $device_no_marker_status instead of 125"
grep -Fxq \
  'xcrun devicectl device uninstall app --device fixture-device fi.siriusbusiness.nvpn.UITests.xctrunner --quiet' \
  "$scoped_cleanup_log" \
  || fail "forced launch timeout did not uninstall only the nVPN XCTest runner"
[[ "$(grep -Fxc installation-probe "$scoped_cleanup_log")" -eq 1 ]] \
  || fail "forced launch timeout did not wait for scoped runner absence"
[[ "$(grep -c '^xcrun ' "$scoped_cleanup_log")" -eq 1 ]] \
  || fail "forced launch timeout performed broad or repeated device cleanup"

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
        "pReShArEdKeY = fake-preshared-key-material\n"
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

isolated_psk="$TEMP_ROOT/isolated-preshared-key.log"
printf '%s\n' 'fake-preshared-key-material' >"$isolated_psk"
if ios_release_network_assert_retained_no_secrets \
    "$spec" "$isolated_psk" 2>/dev/null
then
  fail "isolated WireGuard PresharedKey survived the retained-artifact scan"
fi
[[ "$(ios_release_network_private_data redact "$spec" "$isolated_psk")" == true ]] \
  || fail "isolated WireGuard PresharedKey was not redacted"
grep -Fq '<redacted-private-gate-input>' "$isolated_psk" \
  || fail "isolated WireGuard PresharedKey redaction was not persisted"
ios_release_network_assert_retained_no_secrets "$spec" "$isolated_psk"

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
  'ios_release_network_validate_disconnect_markers' \
  'NVPN_XCUITEST_RUN_ID=$runner_run_id' \
  'NVPN_IOS_XCTEST_LAUNCH_TIMEOUT_SECS' \
  'NVPN_IOS_XCTEST_CLEANUP_TIMEOUT_SECS' \
  'NVPN_IOS_DISCONNECT_CLEANUP_TOTAL_TIMEOUT_SECS'
do
  grep -Fq -- "$token" "$RUNNER" \
    || fail "runner contract lacks: $token"
done

disconnect="$TEMP_ROOT/disconnect-markers.log"
printf '%s\n' 'NVPN_IOS_RELEASE_DISCONNECT_PASSED=1' >"$disconnect"
ios_release_network_validate_disconnect_markers "$disconnect" ""
if ios_release_network_validate_disconnect_markers \
    "$disconnect" "$spec" 2>/dev/null
then
  fail "underlay cleanup accepted no Wi-Fi restoration marker"
fi
printf '%s\n' \
  'NVPN_IOS_RELEASE_DISCONNECT_PASSED=1' \
  'NVPN_IOS_RELEASE_HOME_WIFI_RESTORED=1' >"$disconnect"
ios_release_network_validate_disconnect_markers "$disconnect" "$spec"
if ios_release_network_validate_disconnect_markers \
    "$disconnect" "" 2>/dev/null
then
  fail "non-underlay cleanup accepted a Wi-Fi restoration marker"
fi
printf '%s\n' \
  'NVPN_IOS_RELEASE_DISCONNECT_PASSED=1' \
  'NVPN_IOS_RELEASE_HOME_WIFI_ENABLED_NO_SAVED_SSID=1' >"$disconnect"
ios_release_network_validate_disconnect_markers "$disconnect" "$spec"
printf '%s\n' \
  'NVPN_IOS_RELEASE_DISCONNECT_PASSED=1' \
  'NVPN_IOS_RELEASE_HOME_WIFI_RESTORED=1' \
  'NVPN_IOS_RELEASE_HOME_WIFI_ENABLED_NO_SAVED_SSID=1' >"$disconnect"
if ios_release_network_validate_disconnect_markers \
    "$disconnect" "$spec" 2>/dev/null
then
  fail "disconnect cleanup accepted conflicting Wi-Fi restoration markers"
fi
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
