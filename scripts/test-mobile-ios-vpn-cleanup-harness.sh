#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-cleanup-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin"

fail() {
  printf 'iOS VPN cleanup harness failed: %s\n' "$*" >&2
  exit 1
}

cat >"$FIXTURE/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rendered="$*"
if [[ "$rendered" == *"device process launch"*"--payload-url"* ]]; then
  payload_url=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "--payload-url" ]]; then
      payload_url="$argument"
      break
    fi
    previous="$argument"
  done
  decoded="$(python3 - "$payload_url" <<'PY'
import base64
import json
import sys
from urllib.parse import parse_qs, urlparse

encoded = parse_qs(urlparse(sys.argv[1]).query)["arguments"][0]
encoded += "=" * (-len(encoded) % 4)
print(" ".join(json.loads(base64.urlsafe_b64decode(encoded))))
PY
)"
  rendered="$rendered $decoded"
fi
printf '%s\n' "$rendered" >>"$NVPN_TEST_XCRUN_LOG"
if [[ "$rendered" == "devicectl device info details"* ]]; then
  exit 0
fi
if [[ "$rendered" == "devicectl device info apps"* ]]; then
  [[ "${NVPN_TEST_APP_INSTALLED:-0}" == "1" ]] \
    && printf 'Nostr VPN fi.siriusbusiness.nvpn 4.1.4 4001004\n'
  exit 0
fi
if [[ "$rendered" == *"device process launch"*"--nvpn-debug-disconnect-result"* ]]; then
  [[ "${NVPN_TEST_DISCONNECT_LAUNCH_FAIL:-0}" == "1" ]] && exit 74
  exit 0
fi
if [[ "$rendered" == *"device process launch"*"--nvpn-debug-exit-probe"* ]]; then
  exit 0
fi
if [[ "$rendered" == *"device copy from"*"mobile-ios-disconnect-"* ]]; then
  destination="${@: -2:1}"
  printf '{"ok":true,"packetTunnelStatusRawValue":1}\n' >"$destination"
  exit 0
fi
if [[ "$rendered" == *"device copy from"* ]]; then
  exit 75
fi
exit 0
EOF
chmod +x "$FIXTURE/bin/xcrun"

cat >"$FIXTURE/bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-s" ]]; then
  printf 'Darwin\n'
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
chmod +x "$FIXTURE/bin/uname"

COMMON_ENV=(
  PATH="$FIXTURE/bin:$PATH"
  NVPN_IOS_DEVICE=test-device
  NVPN_IOS_TEAM_ID=test-team
  NVPN_IOS_DEVICE_SIGNING_MODE=development
  NVPN_IOS_VPN_START_WAIT_SECS=0
  NVPN_IOS_VPN_RESULT_WAIT_SECS=0
  NVPN_IOS_LIFECYCLE_GATE=0
  NVPN_IDLE_CPU_GATE=0
  NVPN_TEST_XCRUN_LOG="$FIXTURE/xcrun.log"
)

set +e
env "${COMMON_ENV[@]}" "$ROOT/scripts/mobile-ios-smoke.sh" device --vpn-cycle \
  >"$FIXTURE/failure.out" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed probe unexpectedly passed"
grep -Fq -- '--nvpn-debug-exit-probe' "$FIXTURE/xcrun.log" \
  || fail "fixture did not start the test tunnel"
grep -Fq -- '--nvpn-debug-disconnect-result' "$FIXTURE/xcrun.log" \
  || fail "failed probe did not run emergency disconnect"
grep -Fq 'iOS VPN cleanup verified: packet tunnel is disconnected' "$FIXTURE/failure.out" \
  || fail "failed probe did not verify emergency disconnect"

: >"$FIXTURE/xcrun.log"
set +e
env "${COMMON_ENV[@]}" \
  NVPN_TEST_APP_INSTALLED=1 \
  NVPN_TEST_DISCONNECT_LAUNCH_FAIL=1 \
  NVPN_IOS_INSTALL=1 \
  "$ROOT/scripts/mobile-ios-smoke.sh" device --install \
  >"$FIXTURE/install.out" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "unsafe replacement unexpectedly passed"
grep -Fq 'Refusing to replace fi.siriusbusiness.nvpn' "$FIXTURE/install.out" \
  || fail "unsafe replacement did not report its guard"
if grep -Fq 'device install app' "$FIXTURE/xcrun.log"; then
  fail "unsafe replacement reached the install command"
fi

if rg -q -- '--domain-type appGroupDataContainer|NVPN_IOS_ALLOW_LEGACY_APP_DATA_CLEANUP' \
  "$ROOT/scripts/mobile-ios-smoke.sh" "$ROOT/scripts/mobile-ios-android-join-e2e.sh"
then
  fail "physical iOS gates retain a broken CoreDevice App Group copy or legacy receipt path"
fi
grep -Fq 'DEVICE_SIGNING_MODE="${NVPN_IOS_DEVICE_SIGNING_MODE:-adhoc}"' \
  "$ROOT/scripts/mobile-ios-smoke.sh" \
  || fail "physical iOS gates do not default to company Ad Hoc signing"
if grep -Fq 'mode="auto"' "$ROOT/scripts/mobile-ios-smoke.sh"; then
  fail "physical iOS signing still has an implicit development-signing mode"
fi
if rg -q -- '--terminate-existing' \
  "$ROOT/scripts/mobile_env.sh" \
  "$ROOT/scripts/mobile-ios-smoke.sh" \
  "$ROOT/scripts/mobile-ios-android-join-e2e.sh"
then
  fail "physical iOS automation can terminate the embedded packet tunnel"
fi
grep -Fq -- '--payload-url "nvpn://debug/automation?arguments=$encoded_arguments"' \
  "$ROOT/scripts/mobile_env.sh" \
  || fail "physical iOS automation does not use the non-terminating URL command channel"

python3 - \
  "$ROOT/ios/Sources/AppModel.swift" \
  "$ROOT/ios/Sources/PacketTunnelController.swift" \
  "$ROOT/ios/Sources/AppModelDebugAutomation.swift" \
  "$ROOT/scripts/mobile-ios-android-join-e2e.sh" \
  "$ROOT/ios/Sources/AppModelSupport.swift" \
  "$ROOT/ios/PacketTunnel/PacketTunnelProvider.swift" \
  "$ROOT/scripts/ios-profiles" \
  "$ROOT/ios/Sources/AppModelDebugJoinAutomation.swift" \
  "$ROOT/ios/Sources/AppModelDebugURLAutomation.swift" \
  "$ROOT/ios/Sources/AppModelDebugLifecycle.swift" \
  "$ROOT/ios/Sources/NostrVpnIosApp.swift" \
  "$ROOT/scripts/lib-mobile-ios-lifecycle.sh" \
  "$ROOT/scripts/release-gate.sh" <<'PY'
import sys

app_model = open(sys.argv[1], encoding="utf-8").read()
controller = open(sys.argv[2], encoding="utf-8").read()
automation = open(sys.argv[3], encoding="utf-8").read()
join_gate = open(sys.argv[4], encoding="utf-8").read()
app_support = open(sys.argv[5], encoding="utf-8").read()
packet_tunnel = open(sys.argv[6], encoding="utf-8").read()
profiles = open(sys.argv[7], encoding="utf-8").read()
join_automation = open(sys.argv[8], encoding="utf-8").read()
url_automation = open(sys.argv[9], encoding="utf-8").read()
lifecycle_automation = open(sys.argv[10], encoding="utf-8").read()
ios_app = open(sys.argv[11], encoding="utf-8").read()
lifecycle_gate = open(sys.argv[12], encoding="utf-8").read()
release_gate = open(sys.argv[13], encoding="utf-8").read()
sync = app_model.split("private func syncPacketTunnelConfig", 1)[1].split(
    "private func actionRequiresPacketTunnelConfigSync", 1
)[0]
if "try await vpnController.stopAndWaitForDisconnected()" not in sync:
    raise SystemExit("config refresh does not await a confirmed disconnect")
if "try await vpnController.stop()" in sync:
    raise SystemExit("config refresh still uses the racy fire-and-forget stop")
if "case .disconnecting:" not in controller:
    raise SystemExit("PacketTunnelController.start does not guard a prior disconnect race")
if "throw PacketTunnelControllerError.disconnectTimedOut(status)" not in controller:
    raise SystemExit("disconnect timeout does not fail closed")
start_method = controller.split("func start(", 1)[1].split("private static func hasDefaultRoute", 1)[0]
save_index = start_method.index("try await save(manager)")
if "manager.connection.stopVPNTunnel()" not in start_method[:save_index]:
    raise SystemExit("PacketTunnelController.start can save preferences while the tunnel is active")
if "try await waitForDisconnected(manager)" not in start_method[:save_index]:
    raise SystemExit("PacketTunnelController.start does not confirm disconnect before saving")
if "case .disconnecting:" in start_method[save_index:]:
    raise SystemExit("PacketTunnelController.start still reacts to disconnect only after saving")
if "--nvpn-debug-connect-result" not in automation or "status == 3" not in automation:
    raise SystemExit("iOS join automation does not produce a confirmed-connect result")
approval = join_gate.index("android_action import_join_request")
connect = join_gate.rfind("connect_ios_joiner", 0, approval)
wait = join_gate.index("wait_for_ios_join", approval)
if connect < 0 or not connect < approval < wait:
    raise SystemExit("reverse QR gate does not connect the iOS joiner before Android approval")
first_request = join_gate.index("android_action export_join_request")
admin_connect = join_gate.rfind("connect_ios_joiner", 0, first_request)
if admin_connect < 0:
    raise SystemExit("first QR gate does not connect the iOS admin before approval")
if 'select_ios_mesh "$IOS_ORIGINAL_MESH"' not in join_gate:
    raise SystemExit("bidirectional join cleanup does not restore the original iOS network")
if "--nvpn-debug-select-network-result" not in join_automation:
    raise SystemExit("iOS network selection does not emit an app-core result receipt")
if "activeNetworkId" not in join_automation or '"error": error' not in join_automation:
    raise SystemExit("iOS network selection receipt omits loaded state or the app-core error")
if "--nvpn-debug-select-network-result" not in join_gate:
    raise SystemExit("bidirectional join gate does not request the iOS selection receipt")
if 'result.get("ok") is not True' not in join_gate or 'result.get("activeNetworkId") != sys.argv[2]' not in join_gate:
    raise SystemExit("bidirectional join gate can accept a failed or stale iOS selection")
if 'result.get("enabledNetworkCount") != 1' not in join_gate:
    raise SystemExit("bidirectional join gate does not reject ambiguous enabled-network state")
if "copy_ios_debug_result" not in join_gate:
    raise SystemExit("bidirectional join gate cannot read receipts without terminating the app")
support_copy = join_gate.split("copy_ios_file()", 1)[1].split("copy_ios_debug_result()", 1)[0]
if "--nvpn-debug-export-support-file" not in support_copy:
    raise SystemExit("iOS support diagnostics do not use the explicit app export bridge")
if "--domain-type appGroupDataContainer" in support_copy:
    raise SystemExit("iOS support diagnostics retain a broken CoreDevice App Group copy path")
if 'WAIT_SECS="${NVPN_MOBILE_JOIN_E2E_WAIT_SECS:-15}"' not in join_gate:
    raise SystemExit("physical join delivery can wait longer than the 15-second gate budget")
if '"deliveryCeilingMs"' not in join_gate or '"deliveryElapsedMs"' not in join_gate:
    raise SystemExit("physical join artifact does not preserve per-direction delivery latency")
ios_wait = join_gate.split("wait_for_ios_join()", 1)[1].split("tap_android_resource_if_present()", 1)[0]
if "--nvpn-debug-wait-for-joined-network-base64" not in ios_wait:
    raise SystemExit("iOS joined-network gate does not use a single in-app wait receipt")
if "copy_ios_file" in ios_wait:
    raise SystemExit("iOS joined-network gate repeatedly relaunches the app to read config")
if "copy_ios_debug_result" not in ios_wait:
    raise SystemExit("iOS joined-network gate does not poll its non-terminating receipt")
if "--nvpn-debug-wait-for-joined-network-base64" not in join_automation:
    raise SystemExit("iOS join automation has no bounded signed-roster wait")
selection = join_gate.split("select_ios_mesh()", 1)[1].split("connect_ios_joiner()", 1)[0]
if 'copy_ios_file "$result_name"' in selection:
    raise SystemExit("iOS network selection still terminates the app while it writes its receipt")
connect_receipt = join_gate.split("connect_ios_joiner()", 1)[1].split("config_has_joined_mesh()", 1)[0]
if 'copy_ios_file "$result_name"' in connect_receipt:
    raise SystemExit("iOS connect still terminates the app while it writes its receipt")
if 'mobile-ios-join-connect-$$-$RANDOM.json' not in connect_receipt:
    raise SystemExit("bidirectional iOS connect phases can reuse a stale device receipt")
if 'rm -f "$destination"' not in join_gate.split("copy_ios_debug_result()", 1)[1].split("copy_android_file()", 1)[0]:
    raise SystemExit("iOS receipt polling cannot observe a newer atomic receipt")
if 'result.get("phase") != "finished"' not in connect_receipt or 'result.get("startError")' not in connect_receipt:
    raise SystemExit("iOS connect does not surface first-install VPN authorization failures early")
if '?? "group.' in app_model or '?? "group.' in packet_tunnel:
    raise SystemExit("iOS target still silently falls back to an unrelated App Group")
if "migrateLegacySupportDirectoryIfNeeded" not in app_support:
    raise SystemExit("iOS App Group rollout does not migrate existing app state")
if "for: .applicationSupportDirectory" not in app_support:
    raise SystemExit("iOS App Group migration does not inspect the legacy app container")
if '"[[networks]]"' not in app_support:
    raise SystemExit("iOS App Group migration cannot replace an empty seeded config")
if 'legacy-private-container-migrated' not in app_support:
    raise SystemExit("iOS App Group migration has no durable one-time marker")
if "debugResultsDirectory" not in automation:
    raise SystemExit("iOS debug receipts do not have a private-container bridge")
if "--nvpn-debug-export-support-file" not in automation:
    raise SystemExit("iOS App Group support files cannot be exported for physical diagnostics")
if "Nostr VPN Debug Results" not in join_gate:
    raise SystemExit("bidirectional join diagnostics cannot read current App Group files")
if 'unavailable.error = "Shared app storage setup failed:' not in app_model:
    raise SystemExit("iOS App Group setup failures remain silent")
if "iosDebugLogLimitBytes" not in app_support or "moveItem(at: logURL" not in app_support:
    raise SystemExit("iOS app diagnostic log is not bounded")
if "packetDebugLogLimitBytes" not in packet_tunnel or "moveItem(at: logUrl" not in packet_tunnel:
    raise SystemExit("iOS packet-tunnel diagnostic log is not bounded")
if "verify_profile_app_group" not in profiles or "com.apple.security.application-groups" not in profiles:
    raise SystemExit("iOS provisioning profiles are not checked for the requested App Group")
if "plistlib.loads(sys.stdin.buffer.read())" not in profiles:
    raise SystemExit("iOS profile verification assumes seekable piped input")
if 'action == "automation"' not in app_model:
    raise SystemExit("iOS app does not receive physical automation without a process restart")
if "debugArguments(fromBase64URL" not in url_automation:
    raise SystemExit("iOS physical automation URL arguments are not explicitly decoded")
if "@Environment(\\.scenePhase)" not in ios_app or "model.handleScenePhase(phase)" not in ios_app:
    raise SystemExit("iOS app does not forward background/foreground lifecycle changes")
if "case .background:" not in app_model or "suspendNativeCore()" not in app_model:
    raise SystemExit("iOS app does not close its shared native core before suspension")
if "case .active:" not in app_model or "resumeNativeCore()" not in app_model:
    raise SystemExit("iOS app does not reopen its native core after foregrounding")
if "core?.close()" not in app_model or "core = nil" not in app_model:
    raise SystemExit("iOS suspension path can retain the shared Cashu wallet lock")
if "--nvpn-debug-lifecycle-result" not in lifecycle_automation:
    raise SystemExit("iOS physical build cannot report native-core lifecycle state")
if "com.apple.Preferences" not in lifecycle_gate:
    raise SystemExit("iOS lifecycle gate does not physically background the app")
if lifecycle_gate.count("ios_lifecycle_wait_for_phase") < 2:
    raise SystemExit("iOS lifecycle gate does not prove background and foreground phases")
if 'IOS_LIFECYCLE_GATE="${NVPN_IOS_LIFECYCLE_GATE:-1}"' not in open(
    sys.argv[1].replace("ios/Sources/AppModel.swift", "scripts/mobile-ios-smoke.sh"),
    encoding="utf-8",
).read():
    raise SystemExit("physical iOS lifecycle gate is not enabled by default")
if "run_mobile_idle_cpu_gates" not in release_gate:
    raise SystemExit("release gate no longer reaches the physical iOS smoke")
ios_smoke = open(
    sys.argv[1].replace("ios/Sources/AppModel.swift", "scripts/mobile-ios-smoke.sh"),
    encoding="utf-8",
).read()
if 'get("hardwareProperties", {}).get("udid")' not in ios_smoke:
    raise SystemExit("iOS signing does not resolve the exact selected device UDID")
if 'printf \'%s\\n\' "$NVPN_IOS_DEVICE_UDID"' in ios_smoke:
    raise SystemExit("iOS signing can still trust a stale unrelated device UDID")
PY

printf 'iOS VPN cleanup harness passed\n'
