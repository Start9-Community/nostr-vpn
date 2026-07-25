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
grep -Fq 'NVPN_ANDROID_EXIT_DNS_USE_SHIPPED_UI=1' "$gate" \
  || { echo "Android physical DNS cases do not require the shipped UI driver" >&2; exit 1; }
grep -Fq 'NVPN_IOS_LIFECYCLE_GATE="$lifecycle_gate"' "$gate" \
  || { echo "iOS mobile exit cases ignore the lifecycle-gate mode" >&2; exit 1; }
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
    }
    arguments = [
        sys.executable,
        str(validator),
        str(result),
        str(summary),
        "",
        "1",
        "",
        "0",
        "",
        "",
        "",
        "",
        "",
        "0",
        "0",
        "",
    ]
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise SystemExit(f"valid iOS UDP echo receipt failed: {completed.stderr}")
    validated = json.loads(summary.read_text(encoding="utf-8"))
    if validated.get("replyPackets") != 4 or validated.get("replyObserved") is not True:
        raise SystemExit(f"iOS UDP echo summary lost reply evidence: {validated!r}")

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
