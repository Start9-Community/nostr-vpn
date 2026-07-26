#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$ROOT/scripts/mobile-wireguard-exit-e2e.sh"
android_smoke="$ROOT/scripts/mobile-android-smoke.sh"
android_tun_summary="$ROOT/scripts/write-mobile-android-tun-summary.py"
ios_smoke="$ROOT/scripts/mobile-ios-smoke.sh"
ios_probe_validator="$ROOT/scripts/validate-mobile-ios-vpn-probe.py"
ios_debug_automation="$ROOT/ios/Sources/AppModelDebugAutomation.swift"
ios_tun_probe="$ROOT/ios/Sources/AppModelDebugTunProbe.swift"
ios_url_automation="$ROOT/ios/Sources/AppModelDebugURLAutomation.swift"
ios_ui="$ROOT/ios/UITests/NostrVpnIosUITests.swift"
ios_lifecycle_ui="$ROOT/ios/UITests/NostrVpnLifecycleUITests.swift"
ios_lifecycle_lib="$ROOT/scripts/lib-mobile-ios-lifecycle.sh"
ios_project="$ROOT/ios/project.yml"
ios_internet="$ROOT/ios/Sources/InternetViews.swift"
ios_settings="$ROOT/ios/Sources/SettingsViews.swift"
android_internet="$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidInternet.kt"
android_dns="$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidExitDns.kt"
server="$ROOT/scripts/mobile-wireguard-exit-server.sh"

for label in automatic-profile cloudflare-doh quad9-doh custom-doh through-exit; do
  grep -Fq "$label" "$gate" || {
    echo "mobile exit gate is missing the $label DNS case" >&2
    exit 1
  }
done

grep -Fq 'doh_flow_count' "$gate" \
  || { echo "mobile exit gate does not require resolver-specific DoH traffic" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_SWITCH_TO_DIRECT_WHILE_CONNECTED="$final"' "$gate" \
  || { echo "Android gate does not exercise WireGuard -> Direct while connected" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_PACKAGE="${NVPN_ANDROID_PACKAGE:-fi.siriusbusiness.nvpn}"' "$gate" \
  || { echo "Android gate does not use the single canonical app package" >&2; exit 1; }
grep -Fq 'assert_single_android_app' "$gate" \
  || { echo "Android gate does not reject stale parallel nVPN installs" >&2; exit 1; }
grep -Fq 'assert_single_android_app_process' "$android_smoke" \
  || { echo "Android physical smoke does not reject duplicate canonical app processes" >&2; exit 1; }
stale_package_filter='$0 == "org.nostrvpn.app" || ($0 ~ /^fi\.siriusbusiness\.nvpn(\.|$)/ && $0 != "fi.siriusbusiness.nvpn")'
grep -Fq "$stale_package_filter" "$gate" \
  || { echo "Android stale-package filter is missing or over-escaped" >&2; exit 1; }
filtered_packages="$(
  printf '%s\n' \
    fi.siriusbusiness.nvpn \
    fi.siriusbusiness.nvpn.debug \
    fi.siriusbusiness.nvpn.test \
    fi.siriusbusiness.other \
    org.nostrvpn.app \
    | awk "$stale_package_filter"
)"
[[ "$filtered_packages" == $'fi.siriusbusiness.nvpn.debug\nfi.siriusbusiness.nvpn.test\norg.nostrvpn.app' ]] \
  || { echo "Android stale-package filter does not select only parallel nVPN installs" >&2; exit 1; }
grep -Fq 'NVPN_IOS_SWITCH_TO_DIRECT_WHILE_CONNECTED="$final"' "$gate" \
  || { echo "iOS gate does not exercise WireGuard -> Direct while connected" >&2; exit 1; }
grep -Fq 'LIFECYCLE_GATE="${NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE:-1}"' "$gate" \
  || { echo "standalone mobile exit gate does not retain lifecycle coverage by default" >&2; exit 1; }
grep -Fq 'if ! bool_is_true "${NVPN_MOBILE_WG_EXIT_IMAGE_READY:-0}"; then' "$gate" \
  || { echo "parallel mobile exit lanes cannot reuse their prebuilt fixture image" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_LIFECYCLE_GATE="$lifecycle_gate"' "$gate" \
  || { echo "Android mobile exit cases ignore the lifecycle-gate mode" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_EXPECT_WIREGUARD_ENDPOINT="$HOST_IP:$HOST_PORT"' "$gate" \
  || { echo "Android mobile exit cases do not pin the expected WireGuard endpoint" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_EXIT_DNS_USE_SHIPPED_UI=1' "$gate" \
  || { echo "Android physical DNS cases do not require the shipped UI driver" >&2; exit 1; }
grep -Fq 'NVPN_IOS_LIFECYCLE_GATE="$lifecycle_gate"' "$gate" \
  || { echo "iOS mobile exit cases ignore the lifecycle-gate mode" >&2; exit 1; }
grep -Fq 'NVPN_IOS_EXPECT_WIREGUARD_ENDPOINT="$HOST_IP:$HOST_PORT"' "$gate" \
  || { echo "iOS mobile exit cases do not pin the expected WireGuard endpoint" >&2; exit 1; }
grep -Fq 'run_ios_exit_dns_shipped_ui_case_gate' "$gate" \
  || { echo "iOS physical DNS cases do not execute their shipped-controls XCTest" >&2; exit 1; }
grep -Fq 'testConfigureExitDnsForPhysicalPacketProbe' "$gate" \
  || { echo "iOS physical DNS gate omits the per-case shipped-controls XCTest" >&2; exit 1; }
grep -Fq 'grep -Fxq "NVPN_XCUITEST_RUN_ID=$run_id"' "$gate" \
  || { echo "iOS physical DNS gate accepts a stale runner receipt" >&2; exit 1; }
grep -Fq 'grep -Fxq "NVPN_EXIT_DNS_UI_CONFIG_PERSISTED=$label"' "$gate" \
  || { echo "iOS physical DNS gate does not require the exact per-case UI receipt" >&2; exit 1; }
grep -Fq 'NVPN_IOS_EXIT_DNS_USE_SHIPPED_UI=1' "$gate" \
  || { echo "iOS packet probes do not consume the UI-persisted DNS config" >&2; exit 1; }
grep -Fq 'NVPN_IOS_EXPECT_DEBUG_DNS_INJECTED=0' "$gate" \
  || { echo "iOS packet probes do not fail closed on debug DNS injection" >&2; exit 1; }
grep -Fq 'IOS_CLEANUP_ARMED=1' "$gate" \
  || { echo "iOS physical DNS gate never arms emergency tunnel cleanup" >&2; exit 1; }
grep -Fq '"$ROOT/scripts/mobile-ios-smoke.sh" device --disconnect' "$gate" \
  || { echo "iOS physical DNS gate cannot confirm disconnect after UI failure" >&2; exit 1; }
python3 - "$gate" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("run_ios_case()")
end = text.index("\nDNS_CASES=", start)
body = text[start:end]
ui = body.index("run_ios_exit_dns_shipped_ui_case_gate")
packet = body.index('"$ROOT/scripts/mobile-ios-smoke.sh"')
if ui >= packet:
    raise SystemExit("iOS packet probe starts before the shipped UI persistence receipt")
PY

grep -Fq 'run_android_direct_while_tunnel_probe' "$android_smoke" \
  || { echo "Android smoke lacks a connected split-tunnel Internet probe" >&2; exit 1; }
grep -Fq 'run_android_app_network_probe' "$android_smoke" \
  || { echo "Android smoke does not prove DNS and HTTPS from the shipped app process" >&2; exit 1; }
grep -Fq 'run_android_active_vpn_lifecycle_gate' "$android_smoke" \
  || { echo "Android smoke does not lifecycle-test the active VPN" >&2; exit 1; }
grep -Fq 'ANDROID_LIFECYCLE_CYCLES="${NVPN_ANDROID_LIFECYCLE_CYCLES:-3}"' "$android_smoke" \
  || { echo "Android active lifecycle does not default to three cycles" >&2; exit 1; }
grep -Fq 'ANDROID_LIFECYCLE_BACKGROUND_DWELL_SECS="${NVPN_ANDROID_LIFECYCLE_BACKGROUND_DWELL_SECS:-10}"' "$android_smoke" \
  || { echo "Android active lifecycle does not default to a ten-second dwell" >&2; exit 1; }
grep -Fq 'for cycle in $(seq 1 "$ANDROID_LIFECYCLE_CYCLES")' "$android_smoke" \
  || { echo "Android active lifecycle does not execute every configured cycle" >&2; exit 1; }
grep -Fq 'wireguard-exit-after-foreground-$cycle' "$android_smoke" \
  || { echo "Android active lifecycle does not re-run DNS/HTTPS after every foreground" >&2; exit 1; }
grep -Fq 'scalar(wireguard, "endpoint") != expected_endpoint' "$android_smoke" \
  || { echo "Android post-foreground probe does not validate tunnel identity" >&2; exit 1; }
grep -Fq 'Android active-VPN background/foreground lifecycle gate passed' "$android_smoke" \
  || { echo "Android active lifecycle does not emit a distinct proof receipt" >&2; exit 1; }
python3 - "$android_smoke" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('if [[ "$vpn_cycle" -eq 1 ]]; then', text.index("wait_for_android_build_metadata"))
body = text[start:]
connected = body.index('wait_until "$VPN_START_WAIT_SECS" vpn_active')
lifecycle = body.index("run_android_active_vpn_lifecycle_gate")
cleanup = body.index("cleanup_android_vpn_after_pass")
direct = body.index("run_android_direct_network_probe after-disconnect")
if not connected < lifecycle < cleanup < direct:
    raise SystemExit(
        "Android active lifecycle must run after connect and before cleanup/Direct restoration"
    )
PY
grep -Fq 'secureDnsSuccesses' "$android_smoke" \
  || { echo "Android smoke does not require a production authenticated-DoH success" >&2; exit 1; }
grep -Fq 'vpn_state_present' "$android_smoke" \
  || { echo "Android connected Direct probe can pass with no VPN network" >&2; exit 1; }
grep -Fq 'select_android_direct_ui' "$android_smoke" \
  || { echo "Android smoke does not select Direct through the shipped UI" >&2; exit 1; }
grep -Fq 'source_match.group(1) if source_match else "direct"' "$android_smoke" \
  || { echo "Android Direct persistence check rejects the omitted default value" >&2; exit 1; }
grep -Fq 'wireguard_enabled = bool(' "$android_smoke" \
  || { echo "Android Direct persistence check does not reject enabled WireGuard" >&2; exit 1; }
grep -Fq 'if [[ -n "$dns_servers" ]]' "$android_smoke" \
  || { echo "Android Direct probe does not reject VPN-owned DNS" >&2; exit 1; }
grep -Fq 'android_validated_underlying_dns_servers' "$android_smoke" \
  || { echo "Android Direct probe does not verify native device DNS" >&2; exit 1; }
grep -Fq 'android_vpn_has_default_route' "$android_smoke" \
  || { echo "Android connected Direct probe does not reject a stale full-tunnel route" >&2; exit 1; }
grep -Fq 'throw\b|unreachable\b' "$android_smoke" \
  || { echo "Android connected Direct probe mistakes excluded defaults for captured routes" >&2; exit 1; }
for shipped_ui_contract in \
  configure_android_exit_dns_ui \
  'tap_android_ui description "$mode_description"' \
  'tap_android_ui description "$provider_description"' \
  'shell input keycombination -t 40 KEYCODE_CTRL_LEFT KEYCODE_A' \
  'assert_android_ui_validation "Enter an HTTPS DoH URL."' \
  'assert_android_ui_validation "DoH URL must use HTTPS."' \
  'assert_android_ui_validation "Enter at least one bootstrap IP."' \
  'assert_android_ui_validation "Enter at least one DNS server IP."' \
  wait_for_android_exit_dns_persistence
do
  grep -Fq "$shipped_ui_contract" "$android_smoke" \
    || { echo "Android shipped DNS UI driver is missing: $shipped_ui_contract" >&2; exit 1; }
done
if grep -Fq 'seq 1 96' "$android_smoke"; then
  echo "Android shipped DNS UI driver still clears fields with 96 key events" >&2
  exit 1
fi
grep -Fq 'if truthy "$EXIT_DNS_USE_SHIPPED_UI"; then' "$android_smoke" \
  || { echo "Android DNS setup cannot select the shipped UI path" >&2; exit 1; }
grep -Fq 'write-mobile-android-tun-summary.py' "$android_smoke" \
  || { echo "Android physical packet evidence does not use its standalone summarizer" >&2; exit 1; }
python3 - "$android_tun_summary" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

summarizer = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    summary = root / "summary.json"
    completed = subprocess.run(
        [
            sys.executable,
            str(summarizer),
            str(summary),
            "10.44.255.254",
            "1",
            "10",
            "14",
            "4",
            "1000",
            "1256",
            "20",
            "24",
            "2000",
            "2256",
            "0",
            "0",
            str(root / "ping.txt"),
            "0",
            "250",
            "500",
            "5",
            "100",
            "1",
            str(root / "runtime.json"),
            str(root / "ping-summary.json"),
            str(root / "link.txt"),
            str(root / "link-summary.tsv"),
            str(root / "build.json"),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise SystemExit(f"Android TUN summary fixture failed: {completed.stderr}")
    value = json.loads(summary.read_text(encoding="utf-8"))
    expected = {
        "observed": 4,
        "observedBytesRead": 256,
        "observedWritten": 4,
        "replyRequired": True,
        "replyObserved": True,
        "droppedDelta": 0,
    }
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            raise SystemExit(
                f"Android TUN summary {key}={value.get(key)!r} expected={expected_value!r}"
            )
PY

grep -Fq -- '--nvpn-debug-exit-dns-mode' "$ios_smoke" \
  || { echo "iOS smoke does not send DNS settings through the app" >&2; exit 1; }
grep -Fq 'if [[ -n "$EXIT_DNS_MODE" ]] && ! bool_is_true "$EXIT_DNS_USE_SHIPPED_UI"; then' "$ios_smoke" \
  || { echo "iOS smoke cannot preserve a shipped-UI DNS selection" >&2; exit 1; }
grep -Fq 'debugDnsInjected' "$ios_debug_automation" \
  || { echo "iOS packet receipt does not record whether debug DNS was injected" >&2; exit 1; }
grep -Fq 'expected_debug_dns_injected' "$ios_probe_validator" \
  || { echo "iOS packet validator does not enforce debugDnsInjected" >&2; exit 1; }
grep -Fq 'expect_active_lifecycle' "$ios_probe_validator" \
  || { echo "iOS packet validator does not require the active-tunnel lifecycle receipt" >&2; exit 1; }
grep -Fq 'expected_active_lifecycle_cycles' "$ios_probe_validator" \
  || { echo "iOS packet validator ignores the configured active lifecycle cycle count" >&2; exit 1; }
grep -Fq 'expected_resolve_host' "$ios_probe_validator" \
  || { echo "iOS packet validator cannot distinguish configured DNS probes from optional ones" >&2; exit 1; }
grep -Fq 'expected_fetch_url' "$ios_probe_validator" \
  || { echo "iOS packet validator cannot distinguish configured HTTPS probes from optional ones" >&2; exit 1; }
grep -Fq 'expected_wireguard_endpoint' "$ios_probe_validator" \
  || { echo "iOS packet validator does not pin WireGuard tunnel identity" >&2; exit 1; }
grep -Fq 'run_ios_active_tunnel_lifecycle_gate' "$ios_smoke" \
  || { echo "iOS VPN cycle does not run its lifecycle gate with the tunnel active" >&2; exit 1; }
grep -Fq 'IOS_ACTIVE_TUNNEL_LIFECYCLE_CYCLES="${NVPN_IOS_ACTIVE_TUNNEL_LIFECYCLE_CYCLES:-3}"' "$ios_smoke" \
  || { echo "iOS active lifecycle does not default to three cycles" >&2; exit 1; }
grep -Fq 'testPhysicalActiveTunnelBackgroundForegroundLifecycle' "$ios_lifecycle_ui" \
  || { echo "iOS XCTest does not background a real active packet tunnel" >&2; exit 1; }
grep -Fq 'run_ios_active_tunnel_lifecycle_gate()' "$ios_lifecycle_lib" \
  || { echo "iOS host harness lacks the active-tunnel lifecycle driver" >&2; exit 1; }
grep -Fq -- '--nvpn-debug-await-active-tunnel-lifecycle' "$ios_debug_automation" \
  || { echo "iOS exit probe cannot synchronize with real Home/foreground events" >&2; exit 1; }
grep -Fq 'postForegroundProbe' "$ios_debug_automation" \
  || { echo "iOS exit probe does not mark its traffic as post-foreground" >&2; exit 1; }
grep -Fq 'activeTunnelLifecycleCycleResults' "$ios_debug_automation" \
  || { echo "iOS exit probe does not preserve evidence for every lifecycle cycle" >&2; exit 1; }
grep -Fq 'Active VPN lifecycle verified \(' "$ios_lifecycle_ui" \
  || { echo "iOS XCTest does not wait for each post-foreground packet proof" >&2; exit 1; }
grep -Fq 'driveConnectedDirectIfRequested()' "$ios_lifecycle_ui" \
  || { echo "iOS active lifecycle XCTest strands the combined Direct-restoration gate" >&2; exit 1; }
python3 - "$ios_probe_validator" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

validator = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    result = pathlib.Path(directory) / "result.json"
    summary = pathlib.Path(directory) / "summary.json"
    result.write_text(
        json.dumps(
            {
                "debugDnsInjected": True,
                "exitDnsMode": "encrypted",
                "exitDnsDohProvider": "quad9",
            }
        ),
        encoding="utf-8",
    )
    completed = subprocess.run(
        [
            sys.executable,
            str(validator),
            str(result),
            str(summary),
            "",
            "0",
            "",
            "0",
            "automatic",
            "cloudflare",
            "",
            "",
            "",
            "0",
            "0",
            "0",
            "0",
            "3",
            "",
            "",
            "",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode == 0:
        raise SystemExit("iOS packet validator accepted an injected/mismatched DNS receipt")
    for expected in (
        "debugDnsInjected=True expected=False",
        "exitDnsMode='encrypted' expected='automatic'",
        "exitDnsDohProvider='quad9' expected='cloudflare'",
    ):
        if expected not in completed.stderr:
            raise SystemExit(f"iOS packet validator did not fail closed on {expected}")

    missing_ui_receipt = subprocess.run(
        [
            sys.executable,
            str(validator),
            str(result),
            str(summary),
            "",
            "0",
            "",
            "0",
            "",
            "",
            "",
            "",
            "",
            "1",
            "0",
            "",
            "0",
            "3",
            "",
            "",
            "",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if missing_ui_receipt.returncode == 0:
        raise SystemExit("iOS packet validator accepted Direct without a UI receipt")
    if "directWhileTunnelUiSelectionObserved=None" not in missing_ui_receipt.stderr:
        raise SystemExit("iOS packet validator did not require the Direct UI receipt")
PY
grep -Fq 'sendAndReceiveDebugUdpEchoes' "$ios_tun_probe" \
  || { echo "iOS packet probe does not retain one socket for the UDP echo session" >&2; exit 1; }
grep -Fq 'recv(fd, bytes.baseAddress, bytes.count, 0)' "$ios_tun_probe" \
  || { echo "iOS packet probe does not read and validate real UDP echo replies" >&2; exit 1; }
if grep -Fq 'sendDebugUdpPacket' "$ios_tun_probe"; then
  echo "iOS packet probe still uses the send-and-close pseudo reply check" >&2
  exit 1
fi
python3 - "$ios_probe_validator" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

validator = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    result = pathlib.Path(directory) / "result.json"
    summary = pathlib.Path(directory) / "summary.json"
    receipt = {
        "phase": "finished",
        "finishedAt": "2026-07-25T00:00:00Z",
        "packetTunnelStatusRawValue": 3,
        "vpnEnabled": True,
        "packetTunnelRuntimeStateJson": json.dumps(
            {
                "vpnActive": True,
                "tunPacketsRead": 14,
                "tunBytesRead": 1256,
                "tunPacketsWritten": 24,
                "tunBytesWritten": 2256,
                "tunPacketsDropped": 0,
            }
        ),
        "tunPacketProbeExpectedPackets": 4,
        "tunPacketProbeSentPackets": 4,
        "tunPacketProbeObservedPackets": 4,
        "tunPacketProbeMissingPackets": 0,
        "tunPacketProbeReplyPackets": 4,
        "tunPacketProbeMissingReplyPackets": 0,
        "tunPacketProbeObservedBytesRead": 256,
        "tunPacketProbeObservedWritten": 4,
        "tunPacketProbeObservedBytesWritten": 256,
        "tunPacketProbeDroppedDelta": 0,
        "tunPacketProbeReadIncreased": True,
        "tunPacketProbeBytesReadIncreased": True,
        "tunPacketProbeWrittenIncreased": True,
        "tunPacketProbeBytesWrittenIncreased": True,
        "tunPacketProbeDroppedIncreased": False,
        "tunPacketProbeBaselineRead": 10,
        "tunPacketProbeFinalRead": 14,
        "tunPacketProbeBaselineBytesRead": 1000,
        "tunPacketProbeFinalBytesRead": 1256,
        "tunPacketProbeBaselineWritten": 20,
        "tunPacketProbeFinalWritten": 24,
        "tunPacketProbeBaselineBytesWritten": 2000,
        "tunPacketProbeFinalBytesWritten": 2256,
        "tunPacketProbeBaselineDropped": 0,
        "tunPacketProbeFinalDropped": 0,
        "activeTunnelLifecycleObserved": True,
        "activeTunnelLifecycleCycles": 3,
        "activeTunnelStatusBeforeBackgroundRawValue": 3,
        "activeTunnelStatusAfterForegroundRawValue": 3,
        "postForegroundProbe": True,
        "internetSource": "wireguard",
        "wireguardExitEnabled": True,
        "wireguardExitConfigured": True,
        "wireguardExitEndpoint": "192.0.2.10:51820",
        "resolvedHost": "probe.example",
        "resolvedAddresses": ["192.0.2.53"],
        "url": "https://example.com/",
        "statusCode": 204,
    }
    cycle_results = []
    for cycle in range(1, 4):
        cycle_result = {
            key: value
            for key, value in receipt.items()
            if key.startswith("tunPacketProbe")
        }
        cycle_result.update(
            {
                "cycle": cycle,
                "postForegroundProbe": True,
                "statusBeforeBackgroundRawValue": 3,
                "statusAfterForegroundRawValue": 3,
                "vpnEnabled": True,
                "vpnActive": True,
                "internetSource": "wireguard",
                "wireguardExitEnabled": True,
                "wireguardExitConfigured": True,
                "wireguardExitEndpoint": "192.0.2.10:51820",
                "resolvedHost": "probe.example",
                "resolvedAddresses": ["192.0.2.53"],
                "url": "https://example.com/",
                "statusCode": 204,
                "packetTunnelRuntimeStateJson": receipt[
                    "packetTunnelRuntimeStateJson"
                ],
            }
        )
        cycle_results.append(cycle_result)
    receipt["activeTunnelLifecycleCycleResults"] = cycle_results
    arguments = [
        sys.executable,
        str(validator),
        str(result),
        str(summary),
        "",
        "1",
        "192.0.2.53",
        "0",
        "",
        "",
        "",
        "",
        "",
        "0",
        "1",
        "",
        "1",
        "3",
        "192.0.2.10:51820",
        "probe.example",
        "https://example.com/",
    ]
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise SystemExit(f"valid iOS UDP echo receipt failed: {completed.stderr}")
    validated = json.loads(summary.read_text(encoding="utf-8"))
    if validated.get("replyPackets") != 4 or validated.get("replyObserved") is not True:
        raise SystemExit(f"iOS UDP echo summary lost reply evidence: {validated!r}")

    receipt["activeTunnelStatusAfterForegroundRawValue"] = 1
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode == 0:
        raise SystemExit("iOS packet validator accepted a tunnel lost while backgrounded")
    if "activeTunnelStatusAfterForegroundRawValue=1" not in completed.stderr:
        raise SystemExit("iOS packet validator did not report the post-foreground tunnel loss")
    receipt["activeTunnelStatusAfterForegroundRawValue"] = 3

    receipt["activeTunnelLifecycleCycles"] = 2
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode == 0:
        raise SystemExit("iOS packet validator accepted fewer than the configured cycles")
    if "activeTunnelLifecycleCycles=2 expected=3" not in completed.stderr:
        raise SystemExit("iOS packet validator ignored the configured lifecycle count")
    receipt["activeTunnelLifecycleCycles"] = 3

    receipt["activeTunnelLifecycleCycleResults"][1]["statusCode"] = 500
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode == 0:
        raise SystemExit("iOS packet validator skipped the second foreground HTTPS proof")
    if "activeLifecycleCycle[2].statusCode=500" not in completed.stderr:
        raise SystemExit("iOS packet validator did not identify the failed lifecycle cycle")
    receipt["activeTunnelLifecycleCycleResults"][1]["statusCode"] = 204

    receipt["tunPacketProbeReplyPackets"] = 0
    receipt["tunPacketProbeMissingReplyPackets"] = 4
    receipt["tunPacketProbeReplyError"] = "received 0/4 UDP echo replies"
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode == 0:
        raise SystemExit("iOS packet validator accepted provider counters without UDP replies")
    if "tunPacketProbeReplyPackets=0/4" not in completed.stderr:
        raise SystemExit("iOS packet validator did not report missing real UDP replies")
PY
grep -Fq -- '--nvpn-debug-await-direct-ui-while-connected' "$ios_smoke" \
  || { echo "iOS smoke does not wait for the shipped connected Direct selection" >&2; exit 1; }
if grep -Fq -- '--nvpn-debug-switch-to-direct-while-connected' "$ios_smoke"; then
  echo "iOS smoke still exposes the obsolete debug Direct mutation" >&2
  exit 1
fi
grep -Fq 'directWhileTunnelPacketTunnelStatusRawValue' "$ios_url_automation" \
  || { echo "iOS automation does not record the live tunnel during Direct probing" >&2; exit 1; }
grep -Fq 'directWhileTunnelUiSelectionObserved' "$ios_url_automation" \
  || { echo "iOS automation does not prove the shipped UI selection was observed" >&2; exit 1; }
grep -Fq 'directWhileTunnelHasDefaultRoute' "$ios_url_automation" \
  || { echo "iOS automation does not inspect the installed Direct routes" >&2; exit 1; }
python3 - "$ios_url_automation" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
body = text.split("func runDebugDirectWhileConnected(", 1)[1]
if "dispatch(" in body:
    raise SystemExit("iOS Direct probe still mutates settings instead of observing shipped UI")
PY

for selector in \
  internet-source-picker \
  exit-dns-mode-picker \
  exit-dns-provider-picker \
  exit-dns-custom-url \
  exit-dns-custom-bootstrap-ips \
  exit-dns-through-exit-servers \
  exit-dns-save
do
  grep -Fq "$selector" "$ios_internet" "$ios_settings" \
    || { echo "iOS DNS UI is missing selector $selector" >&2; exit 1; }
done
grep -Fq 'testConfigureExitDnsForPhysicalPacketProbe' "$ios_ui" \
  || { echo "iOS UI tests do not configure each packet-probe DNS case" >&2; exit 1; }
grep -Fq 'testSelectDirectWhilePhysicalTunnelConnected' "$ios_ui" \
  || { echo "iOS UI tests do not tap Direct while the physical tunnel is connected" >&2; exit 1; }
grep -Fq 'NVPN_CONNECTED_DIRECT_UI_PASSED=1' "$ios_ui" \
  || { echo "iOS connected Direct XCTest does not emit an exact receipt" >&2; exit 1; }
grep -Fq 'emit("NVPN_EXIT_DNS_UI_CONFIG_PERSISTED=\(spec.caseName)")' "$ios_ui" \
  || { echo "iOS shipped DNS XCTest does not emit an exact per-case receipt" >&2; exit 1; }
grep -Fq 'NVPN_XCUITEST_EXIT_DNS_SPEC_BASE64: "$(NVPN_XCUITEST_EXIT_DNS_SPEC_BASE64)"' "$ios_project" \
  || { echo "iOS scheme does not bridge the DNS case spec into the test runner" >&2; exit 1; }
grep -Fq 'NVPN_XCUITEST_CONNECTED_DIRECT_GATE: "$(NVPN_XCUITEST_CONNECTED_DIRECT_GATE)"' "$ios_project" \
  || { echo "iOS scheme does not bridge the connected Direct gate into the test runner" >&2; exit 1; }

for selector in \
  internet-source-picker \
  exit-dns-mode \
  exit-dns-provider \
  exit-dns-custom-url \
  exit-dns-custom-bootstrap-ips \
  exit-dns-through-exit-servers \
  exit-dns-save
do
  grep -Fq "$selector" "$android_internet" "$android_dns" \
    || { echo "Android DNS UI is missing selector $selector" >&2; exit 1; }
done

grep -Fq 'nvpn-wg-doh-cf' "$server" \
  || { echo "WireGuard fixture does not count Cloudflare DoH traffic" >&2; exit 1; }
grep -Fq 'nvpn-wg-doh-q9' "$server" \
  || { echo "WireGuard fixture does not count Quad9 DoH traffic" >&2; exit 1; }

echo "mobile WireGuard exit DNS source contract passed"
