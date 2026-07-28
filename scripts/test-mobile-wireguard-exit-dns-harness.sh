#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/test-ios-packet-flow-lifecycle.sh"
gate="$ROOT/scripts/mobile-wireguard-exit-e2e.sh"
android_smoke="$ROOT/scripts/mobile-android-smoke.sh"
android_release_gate="$ROOT/scripts/lib-mobile-android-release-gate.sh"
android_underlay="$ROOT/scripts/lib-mobile-android-underlay.sh"
android_external_probe="$ROOT/scripts/lib-mobile-android-external-probe.sh"
android_vpn_service="$ROOT/android/app/src/main/java/org/nostrvpn/app/vpn/NostrVpnService.kt"
android_tun_summary="$ROOT/scripts/write-mobile-android-tun-summary.py"
ios_smoke="$ROOT/scripts/mobile-ios-smoke.sh"
ios_probe_validator="$ROOT/scripts/validate-mobile-ios-vpn-probe.py"
ios_debug_automation="$ROOT/ios/Sources/AppModelDebugAutomation.swift"
ios_tun_probe="$ROOT/ios/Sources/AppModelDebugTunProbe.swift"
ios_url_automation="$ROOT/ios/Sources/AppModelDebugURLAutomation.swift"
ios_ui="$ROOT/ios/UITests/NostrVpnIosUITests.swift"
ios_lifecycle_ui="$ROOT/ios/UITests/NostrVpnLifecycleUITests.swift"
ios_lifecycle_lib="$ROOT/scripts/lib-mobile-ios-lifecycle.sh"
ios_release_gate="$ROOT/scripts/lib-mobile-ios-release-network.sh"
ios_release_artifact="$ROOT/scripts/lib-mobile-ios-release-artifact.sh"
ios_packet_tunnel="$ROOT/ios/PacketTunnel/PacketTunnelProvider.swift"
ios_packet_flow_bridge="$ROOT/ios/PacketTunnel/PacketFlowBridge.swift"
ios_project_file="$ROOT/ios/NostrVpnIos.xcodeproj/project.pbxproj"
ios_release_binary_audit="$ROOT/scripts/lib-mobile-ios-release-artifact.sh"
ios_hotspot="$ROOT/scripts/lib-mobile-ios-hotspot.sh"
local_fips="$ROOT/scripts/local-fips-workspace.sh"
fips_c_abi="$ROOT/crates/nostr-vpn-app-core/src/c_abi.rs"
mobile_packet_flow="$ROOT/crates/nostr-vpn-app-core/src/mobile_tunnel/ios_packet_flow.rs"
mobile_native_tun="$ROOT/crates/nostr-vpn-app-core/src/mobile_tunnel/native_tun.rs"
mobile_tunnel_config="$ROOT/crates/nostr-vpn-app-core/src/mobile_tunnel/config.rs"
ios_release_probe="$ROOT/ios/UITests/NostrVpnReleaseNetworkProbe.swift"
ios_release_ui="$ROOT/ios/UITests/NostrVpnReleaseNetworkUITests.swift"
ios_release_ui_support="$ROOT/ios/UITests/NostrVpnReleaseNetworkUI.swift"
ios_release_underlay="$ROOT/ios/UITests/NostrVpnReleaseNetworkUnderlay.swift"
ios_underlay_capture="$ROOT/scripts/capture-mobile-ios-underlay-output.py"
ios_project="$ROOT/ios/project.yml"
ios_internet="$ROOT/ios/Sources/InternetViews.swift"
ios_settings="$ROOT/ios/Sources/SettingsViews.swift"
android_internet="$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidInternet.kt"
android_dns="$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidExitDns.kt"
server="$ROOT/scripts/mobile-wireguard-exit-server.sh"
fixture_lib="$ROOT/scripts/lib-mobile-wireguard-fixture.sh"
remote_native="$ROOT/scripts/mobile-wireguard-exit-remote-native.sh"

for doh_fixture in "$server" "$remote_native"; do
  grep -Fq 'tcp flags syn' "$doh_fixture" \
    || grep -Fq -- '--syn' "$doh_fixture" \
    || {
      echo "$(basename "$doh_fixture") counts pooled DoH teardown traffic as a new resolver use" >&2
      exit 1
    }
done

grep -Fq 'resolve_shared_build_metadata "$ROOT"' "$gate" \
  || { echo "standalone mobile gate does not initialize exact build metadata" >&2; exit 1; }
grep -Fq 'shell input keyevent KEYCODE_ENTER </dev/null' "$android_smoke" \
  && grep -Fq 'shell input text "${line// /%s}" </dev/null' "$android_smoke" \
  || {
    echo "Android multiline UI entry lets adb consume the remaining config" >&2
    exit 1
  }
grep -Fq 'attribute == "descendant-text"' "$android_smoke" \
  && grep -Fq 'internet-source-picker descendant-text' "$android_smoke" \
  || {
    echo "Android Release gate does not read the shipped picker label" >&2
    exit 1
  }
grep -Fq 'write_android_exit_dns_ui_receipt' "$android_smoke" \
  && grep -Fq '"evidenceSource": "shipped-ui-restart-readback"' "$android_smoke" \
  || {
    echo "Android Release UI restart readback does not emit DNS settings evidence" >&2
    exit 1
  }

python3 - "$ROOT/scripts/release-network-evidence.py" <<'PY'
import importlib.util
import json
import pathlib
import tempfile
import sys

spec = importlib.util.spec_from_file_location("network_evidence", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
cases = {
    "automatic-profile": ("automatic", "cloudflare", "", "", ""),
    "cloudflare-doh": ("encrypted", "cloudflare", "", "", ""),
    "quad9-doh": ("encrypted", "quad9", "", "", ""),
    "custom-doh": (
        "encrypted",
        "custom",
        "https://dns.google/dns-query",
        "8.8.8.8",
        "",
    ),
    "through-exit": (
        "through_exit",
        "cloudflare",
        "",
        "",
        "10.99.77.53",
    ),
}
with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    for index, (label, values) in enumerate(cases.items()):
        mode, provider, custom_url, bootstrap, through = values
        payload = {
            "receiptSchema": 1,
            "evidenceSource": "shipped-ui-restart-readback",
            "uiRestartReadback": True,
            "releaseBlackbox": True,
            "exitDnsMode": mode,
            "exitDnsDohProvider": provider,
            "exitDnsCustomDohUrl": custom_url,
            "exitDnsCustomDohBootstrapIps": bootstrap,
            "exitDnsThroughExitServers": through,
            "internetSource": "wireguard",
            "wireguardExitEnabled": True,
            "error": "",
        }
        (root / f"mobile-android-exit-dns-state-{index}.json").write_text(
            json.dumps(payload),
            encoding="utf-8",
        )
    module.validate_android_dns_ui_receipts(root, list(cases))
    support, evidence_paths = module.validate_android_support(
        root, list(cases), "settings-only"
    )
    assert support["dnsSettingsReceiptCount"] == len(cases)
    assert len(evidence_paths) == len(cases)
    custom = root / "mobile-android-exit-dns-state-3.json"
    payload = json.loads(custom.read_text(encoding="utf-8"))
    payload["exitDnsCustomDohBootstrapIps"] = "1.1.1.1"
    custom.write_text(json.dumps(payload), encoding="utf-8")
    try:
        module.validate_android_dns_ui_receipts(root, list(cases))
    except ValueError as error:
        if "custom DoH values" not in str(error):
            raise
    else:
        raise SystemExit("Android Release UI evidence accepted wrong custom bootstrap")
PY

# shellcheck disable=SC1090
source "$fixture_lib"
declare -F mobile_wg_endpoint_fields >/dev/null \
  || { echo "mobile fixture lacks strict endpoint rendering" >&2; exit 1; }
declare -F mobile_wg_dns_case_fields >/dev/null \
  && declare -F mobile_wg_fixture_dns_evidence_snapshot >/dev/null \
  && declare -F mobile_wg_fixture_assert_dns_case_evidence >/dev/null \
  || { echo "mobile fixture lacks the shared DNS evidence contract" >&2; exit 1; }

python3 - "$fixture_lib" "$remote_native" <<'PY'
import pathlib
import sys

fixture = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
remote = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
start = fixture.index("mobile_wg_fixture_dns_evidence_snapshot()")
end = fixture.index("\nmobile_wg_fixture_assert_dns_case_evidence()", start)
snapshot = fixture[start:end]
if snapshot.count("mobile_wg_remote_native dns-evidence-snapshot") != 1:
    raise SystemExit("native DNS evidence still uses multiple remote actions")
if snapshot.count("mobile_wg_fixture_docker exec") != 1:
    raise SystemExit("Docker DNS evidence still uses multiple container actions")
for old_call in (
    "mobile_wg_fixture_dns_count",
    "mobile_wg_fixture_profile_dns_count",
    "mobile_wg_fixture_doh_count",
    "mobile_wg_fixture_through_dns_count",
    "mobile_wg_fixture_forward_dns_count",
):
    if old_call in snapshot:
        raise SystemExit(f"DNS snapshot still fans out through {old_call}")
if "dns-evidence-snapshot)" not in remote:
    raise SystemExit("native fixture lacks an all-counter snapshot action")
for counter in (
    "dns_profile",
    "doh_cf",
    "doh_q9",
    "doh_google",
    "dns_through",
    "dns_forward",
):
    if counter not in remote[remote.index("dns-evidence-snapshot)") :]:
        raise SystemExit(f"native all-counter snapshot omits {counter}")
PY

custom_fields="$(
  mobile_wg_dns_case_fields \
    custom-doh fixture.nvpn.test 10.99.77.1 10.99.77.53
)"
[[ "$custom_fields" \
  == 'encrypted|custom|https://dns.google/dns-query|8.8.8.8||iana.org||doh-google' ]] \
  || { echo "custom DoH is not independently routed through Google" >&2; exit 1; }
through_fields="$(
  mobile_wg_dns_case_fields \
    through-exit fixture.nvpn.test 10.99.77.1 10.99.77.53
)"
[[ "$through_fields" \
  == 'through_exit|cloudflare|||10.99.77.53|through-exit.fixture.nvpn.test|10.99.77.1|dns-through' ]] \
  || { echo "through-exit DNS is not distinct from profile DNS" >&2; exit 1; }
mobile_wg_fixture_assert_dns_case_evidence \
  Android cloudflare-doh doh-cloudflare \
  $'0\t0\t0\t0\t0\t0\t0' $'0\t0\t4\t0\t0\t0\t0' >/dev/null \
  || { echo "valid exclusive Cloudflare evidence was rejected" >&2; exit 1; }
if mobile_wg_fixture_assert_dns_case_evidence \
    Android cloudflare-doh doh-cloudflare \
    $'0\t0\t0\t0\t0\t0\t0' $'1\t1\t4\t0\t0\t0\t0' >/dev/null 2>&1
then
  echo "encrypted DNS accepted a plaintext profile fallback" >&2
  exit 1
fi
if mobile_wg_fixture_assert_dns_case_evidence \
    Android cloudflare-doh doh-cloudflare \
    $'0\t0\t0\t0\t0\t0\t0' $'0\t0\t4\t0\t0\t0\t1' >/dev/null 2>&1
then
  echo "encrypted DNS accepted a forwarded plaintext-DNS fallback" >&2
  exit 1
fi
mobile_wg_fixture_assert_dns_case_evidence \
  iOS through-exit dns-through \
  $'0\t0\t0\t0\t0\t0\t0' $'1\t0\t0\t0\t0\t3\t0' >/dev/null \
  || { echo "valid exclusive through-exit evidence was rejected" >&2; exit 1; }
if mobile_wg_fixture_assert_dns_case_evidence \
    iOS through-exit dns-through \
    $'0\t0\t0\t0\t0\t0\t0' $'1\t2\t0\t0\t0\t3\t0' >/dev/null 2>&1
then
  echo "through-exit DNS accepted a profile-DNS fallback" >&2
  exit 1
fi

assert_endpoint_fields() {
  local raw="$1" port="$2" expected="$3" actual
  actual="$(mobile_wg_endpoint_fields "$raw" "$port")" || {
    echo "valid mobile fixture endpoint was rejected" >&2
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    echo "mobile fixture endpoint rendered incorrectly" >&2
    exit 1
  }
}

assert_endpoint_fields \
  192.0.2.10 51820 $'ipv4\t192.0.2.10\t192.0.2.10:51820'
assert_endpoint_fields \
  fixture.example.test 51820 \
  $'dns\tfixture.example.test\tfixture.example.test:51820'
assert_endpoint_fields \
  2001:db8::10 51820 $'ipv6\t2001:db8::10\t[2001:db8::10]:51820'

for invalid_host in \
  "" \
  " fixture.example.test" \
  "fixture.example.test " \
  "[2001:db8::10]" \
  "fixture.example.test:51820" \
  "https://fixture.example.test" \
  "fixture.example.test/path" \
  "2001:db8::gg" \
  "-fixture.example.test" \
  "fixture..example.test" \
  "999.2.3.4"
do
  if mobile_wg_endpoint_fields "$invalid_host" 51820 >/dev/null 2>&1; then
    echo "mobile fixture accepted malformed raw endpoint host" >&2
    exit 1
  fi
done
for invalid_port in 0 65536 port; do
  if mobile_wg_endpoint_fields fixture.example.test "$invalid_port" \
      >/dev/null 2>&1
  then
    echo "mobile fixture accepted malformed endpoint port" >&2
    exit 1
  fi
done

grep -Fq 'WIREGUARD_ENDPOINT_AUTHORITY' "$gate" \
  && grep -Fq 'Endpoint = $WIREGUARD_ENDPOINT_AUTHORITY' "$gate" \
  && grep -Fq 'NVPN_ANDROID_EXPECT_WIREGUARD_ENDPOINT="$WIREGUARD_ENDPOINT_AUTHORITY"' "$gate" \
  || { echo "mobile gate does not separate raw host from endpoint authority" >&2; exit 1; }
grep -Fq 'mobile_wg_endpoint_family "$fixture_host"' "$ios_hotspot" \
  && grep -Fq 'ping6' "$ios_hotspot" \
  || { echo "Pixel fixture reachability is not IP-family aware" >&2; exit 1; }
grep -Fq 'Self.endpointHost(from: endpoint)' "$ios_packet_tunnel" \
  || { echo "iOS packet tunnel does not parse bracketed WireGuard endpoints" >&2; exit 1; }
grep -Fq 'packetFlow.readPackets' "$ios_packet_flow_bridge" \
  && grep -Fq 'packetFlow.writePackets' "$ios_packet_flow_bridge" \
  && grep -Fq 'nostr_vpn_mobile_tunnel_packet_flow_start' "$ios_packet_flow_bridge" \
  && grep -Fq 'nostr_vpn_mobile_tunnel_packet_flow_send' "$ios_packet_tunnel" \
  || { echo "iOS packet tunnel does not use the supported NEPacketTunnelFlow bridge" >&2; exit 1; }
grep -Fq 'PacketFlowBridge.swift in Sources' "$ios_project_file" \
  && grep -Fq 'ios_release_network_audit_packet_flow_binary' "$ios_release_binary_audit" \
  && grep -Fq 'native utun fd attached' "$ios_release_binary_audit" \
  || { echo "iOS packet-flow source or binary audit is not wired into release artifacts" >&2; exit 1; }
grep -Fq 'include!("mobile_tunnel/ios_packet_flow.rs")' \
  "$ROOT/crates/nostr-vpn-app-core/src/mobile_tunnel.rs" \
  && grep -Fq 'IosPacketFlowRuntime' "$mobile_packet_flow" \
  && grep -Fq 'Java_org_nostrvpn_app_core_NativeCore_mobileTunnelAttachTunFd' "$fips_c_abi" \
  || { echo "mobile packet I/O does not preserve Android fd I/O beside the iOS packet-flow bridge" >&2; exit 1; }
if rg -q \
  'current_ios_utun_fd|CTLIOCGINFO|com\\.apple\\.net\\.utun_control|getpeername|libc::dup|libc::readv|libc::writev|attach_current_tun_fd' \
  "$ROOT/crates/nostr-vpn-app-core/src" "$ROOT/ios/PacketTunnel"
then
  echo "iOS production packet I/O still reaches the private utun fd" >&2
  exit 1
fi
if grep -Fq 'outbound_tx.blocking_send' "$mobile_packet_flow"; then
  echo "iOS packet-flow send can deadlock tunnel shutdown" >&2
  exit 1
fi
if grep -Fq 'nostr_vpn_mobile_tunnel_attach_current_tun_fd' \
  "$ROOT/ios/Bindings/NostrVpnAppCoreC.h"
then
  echo "iOS C ABI still exports private utun fd attachment" >&2
  exit 1
fi
grep -Fq 'if let Some(IpAddr::V4(ip)) =' "$mobile_tunnel_config" \
  && grep -Fq 'wireguard_endpoint_host_ip(&app.wireguard_exit.endpoint)' \
    "$mobile_tunnel_config" \
  || { echo "mobile config can emit a non-IPv4 excluded route" >&2; exit 1; }
grep -Fq 'NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY' "$remote_native" \
  && grep -Fq 'ss -H -lun4' "$remote_native" \
  && grep -Fq 'ss -H -lun6' "$remote_native" \
  && grep -Fq 'ip filter INPUT' "$remote_native" \
  && grep -Fq 'ip6 filter INPUT' "$remote_native" \
  && grep -Fq 'if [[ "$endpoint_family" != "ipv6" ]]' "$remote_native" \
  && grep -Fq 'if [[ "$endpoint_family" != "ipv4" ]]' "$remote_native" \
  && grep -Fq 'meta nfproto ipv4 iifname "$interface" accept' "$remote_native" \
  || { echo "remote native fixture lacks family-specific listener/firewall proof" >&2; exit 1; }
dnsmasq_block="$(
  sed -n '/^    dnsmasq \\$/,/^      --pid-file=/p' "$remote_native"
)"
grep -Fq -- '--bind-interfaces' <<<"$dnsmasq_block" \
  && grep -Fq -- '--listen-address="$local_server_ip"' <<<"$dnsmasq_block" \
  || { echo "remote native DNS is not bound to its explicit lane address" >&2; exit 1; }
if grep -Fq -- '--interface=' <<<"$dnsmasq_block"; then
  echo "remote native DNS implicitly unions every lane with loopback" >&2
  exit 1
fi

for label in automatic-profile cloudflare-doh quad9-doh custom-doh through-exit; do
  grep -Fq "$label" "$fixture_lib" || {
    echo "shared mobile exit contract is missing the $label DNS case" >&2
    exit 1
  }
done

grep -Fq 'mobile_wg_fixture_dns_evidence_snapshot' "$gate" \
  && grep -Fq 'mobile_wg_fixture_assert_dns_case_evidence' "$gate" \
  || { echo "mobile exit gate does not require exclusive resolver evidence" >&2; exit 1; }
grep -Fq 'switch_direct="$final"' "$gate" \
  && grep -Fq 'NVPN_ANDROID_SWITCH_TO_DIRECT_WHILE_CONNECTED="$switch_direct"' "$gate" \
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
grep -Fq '"switchToDirect": direct == "1"' "$gate" \
  && grep -Fq '"$label" "$run_id" "$spec_base64"' "$gate" \
  || { echo "iOS Release gate does not exercise WireGuard -> Direct while connected" >&2; exit 1; }
grep -Fq 'LIFECYCLE_GATE="${NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE:-1}"' "$gate" \
  || { echo "standalone mobile exit gate does not retain lifecycle coverage by default" >&2; exit 1; }
grep -Fq 'mobile_wg_fixture_build' "$gate" \
  && grep -Fq 'elif ! bool_is_true "$image_ready"; then' "$fixture_lib" \
  || { echo "parallel mobile exit lanes cannot reuse their prebuilt fixture image" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_LIFECYCLE_GATE="$lifecycle_gate"' "$gate" \
  || { echo "Android mobile exit cases ignore the lifecycle-gate mode" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_EXPECT_WIREGUARD_ENDPOINT="$WIREGUARD_ENDPOINT_AUTHORITY"' "$gate" \
  || { echo "Android mobile exit cases do not pin the expected WireGuard endpoint" >&2; exit 1; }
grep -Fq 'NVPN_ANDROID_EXIT_DNS_USE_SHIPPED_UI=1' "$gate" \
  || { echo "Android physical DNS cases do not require the shipped UI driver" >&2; exit 1; }
grep -Fq 'RELEASE_BLACKBOX_GATE="${NVPN_MOBILE_WG_EXIT_RELEASE_BLACKBOX:-1}"' "$gate" \
  && grep -Fq -- '--release-network-gate' "$gate" \
  && grep -Fq 'NVPN_ANDROID_WIREGUARD_CONFIG_FILE="$wireguard_config_file"' "$gate" \
  || {
    echo "Android physical DNS cases do not default to the production Release UI path" >&2
    exit 1
  }
if grep -Fq ',,' "$android_smoke"; then
  echo "Android physical smoke uses Bash-4 lowercase expansion on macOS Bash" >&2
  exit 1
fi
[[ "$(grep -Fc 'mobile_wg_fixture_assert_dns_case_evidence' "$gate")" -eq 2 ]] \
  || {
    echo "Android/iOS Release DNS cases do not require shared positive/negative evidence" >&2
    exit 1
  }
grep -Fq 'run_ios_release_network_case' "$gate" \
  && grep -Fq 'ios_release_network_prepare "$IOS_DEVICE_SELECTED"' "$gate" \
  && grep -Fq 'iOS physical network claims require the company-signed Release black-box gate' "$gate" \
  || { echo "iOS physical DNS cases do not require the Release black-box runner" >&2; exit 1; }
grep -Fq -- '-configuration Release' "$ios_release_gate" \
  && grep -Fq 'export NVPN_IOS_RUST_PROFILE=release' "$ios_release_gate" \
  && grep -Fq 'testReleaseNetworkLifecycle' "$ios_release_gate" \
  && grep -Fq 'testReleaseDisconnectCleanup' "$ios_release_gate" \
  || { echo "iOS physical DNS cases do not build/test the company-signed Release app" >&2; exit 1; }
grep -Fq 'driveRapidStartStopStress' "$ios_release_ui" \
  && grep -Fq '"exerciseStartStopStress": create_network == "1"' "$gate" \
  && grep -Fq 'NVPN_IOS_RELEASE_START_STOP_RECOVERED=1' "$ios_release_ui" \
  && grep -Fq 'NVPN_IOS_RELEASE_START_STOP_RECOVERED=1' "$ios_release_gate" \
  || {
    echo "iOS signed Release gate lacks rapid cancel-during-start recovery coverage" >&2
    exit 1
  }
grep -Fq 'NVPN_ANDROID_RAPID_START_STOP_GATE="$first"' "$gate" \
  && grep -Fq 'run_android_release_rapid_start_stop_gate' "$android_release_gate" \
  && grep -Fq '0 10 30 80 160 320 640 1000' "$android_release_gate" \
  && grep -Fq 'android_release_rapid_cancel_once' "$android_release_gate" \
  && grep -Fq 'Android Release rapid cancellation recreated more than one native tunnel' \
    "$android_release_gate" \
  && grep -Fq 'run_android_release_direct_network_probe rapid-cancel-stable-direct 0' \
    "$android_release_gate" \
  && grep -Fq 'run_android_release_exit_network_probe rapid-cancel-full-reconnect' \
    "$android_release_gate" \
  && grep -Fq 'assert_single_android_app_process' "$android_release_gate" \
  || {
    echo "Android signed Release gate lacks real rapid cancel/reconnect recovery coverage" >&2
    exit 1
  }
grep -Fq 'ios_release_network_audit_artifact' "$ios_release_gate" \
  && grep -Fq 'fipsCoreVersion' "$ios_release_artifact" \
  && grep -Fq 'fipsGitTree' "$ios_release_artifact" \
  && grep -Fq 'fipsDependenciesForcedRebuilt' "$ios_release_artifact" \
  && grep -Fq 'NVPN_EXPECTED_FIPS_VERSION' "$ios_release_gate" \
  && grep -Fq 'rglob("fips_core-*.d")' "$ios_release_artifact" \
  && grep -Fq 'fips_core::transport' "$ios_release_artifact" \
  && grep -Fq 'packetTunnelCodeDirectoryHash' "$ios_release_artifact" \
  && grep -Fq 'appCodeDirectoryHash' "$ios_release_artifact" \
  && grep -Fq 'paid_exit::wallet_worker' "$ios_release_artifact" \
  && grep -Fq 'nostr_vpn_update_check' "$ios_release_artifact" \
  && grep -Fq '"paidExitWalletWorkerCompiled": False' "$ios_release_artifact" \
  && grep -Fq '"updaterCompiled": False' "$ios_release_artifact" \
  || { echo "iOS Release gate lacks exact app/tunnel/FIPS artifact receipts" >&2; exit 1; }
grep -Fq 'nvpn_verify_local_fips_metadata' "$ROOT/tools/run-ios" \
  && grep -Fq 'nvpn_force_rebuild_local_fips_target' "$ROOT/tools/run-ios" \
  && grep -Fq 'checkoutPathSha256' "$local_fips" \
  && ! grep -Fq '"checkoutPath":' "$local_fips" \
  || { echo "iOS Release build lacks sanitized exact local-FIPS resolution/rebuild proof" >&2; exit 1; }
if grep -Fq 'nostr_vpn_fips_core_version' "$fips_c_abi"; then
  echo "mobile linkage gate retains a self-attested FIPS version C ABI" >&2
  exit 1
fi
grep -Fq 'ios_release_network_company_signing' "$ios_release_gate" \
  && grep -Fq 'profile.get("TeamIdentifier") != [team_id]' "$ios_release_artifact" \
  && grep -Fq 'app and Packet Tunnel use different signing certificates' "$ios_release_artifact" \
  && grep -Fq 'Release signer is not the expected company organization' "$ios_release_artifact" \
  || { echo "iOS Release gate does not pin the Sirius Business app/tunnel signer" >&2; exit 1; }
grep -Fq 'build-for-testing' "$ios_release_gate" \
  && grep -Fq 'test-without-building' "$ios_release_gate" \
  && grep -Fq 'IOS_RELEASE_NETWORK_BASE_TREE_SHA' "$ios_release_artifact" \
  && grep -Fq 'installedBuildNumber' "$ios_release_artifact" \
  || { echo "iOS Release cases do not reuse/read back one exact signed artifact" >&2; exit 1; }
grep -Fq 'NVPN_IOS_EXPECTED_DEVICE_NAME' "$gate" "$ios_release_gate" \
  && grep -Fq '"selectedPhysicalDevice": selected_device' "$ios_release_artifact" \
  && grep -Fq '"explicitPhysicalDeviceVerified": True' "$ios_release_gate" \
  || { echo "iOS Release gate does not pin and receipt the explicitly selected phone" >&2; exit 1; }
grep -Fq 'capture-mobile-ios-underlay-output.py' "$ios_release_gate" \
  && grep -Fq 'packetTunnelProcessIdentifiers' "$ios_underlay_capture" \
  && grep -Fq 'distinct packet-tunnel PIDs' "$ios_underlay_capture" \
  && grep -Fq '"requiredCheckpoints": sorted(required_checkpoints)' "$ios_underlay_capture" \
  && grep -Fq 'checkpoints without a valid process observation=' "$ios_underlay_capture" \
  && grep -Fq 'self.update_checkpoint("active-session-end")' "$ios_underlay_capture" \
  && grep -Fq 'if required != expected:' "$ios_release_gate" \
  && grep -Fq 'if not expected.issubset(observed):' "$ios_release_gate" \
  || { echo "iOS Release gate does not independently prove stable app/tunnel processes" >&2; exit 1; }
grep -Fq '"NVPN_IOS_RELEASE_RUN_ID=$run_id"' "$ios_release_gate" \
  && grep -Fq 'emit("NVPN_IOS_RELEASE_RUN_ID=\(spec.runId)")' "$ios_release_ui" \
  || { echo "iOS Release runner accepts stale per-case marker receipts" >&2; exit 1; }
grep -Fq 'XCTAssertTrue(app.launchArguments.isEmpty)' "$ios_release_ui" \
  && grep -Fq 'XCTAssertTrue(app.launchEnvironment.isEmpty)' "$ios_release_ui" \
  || { echo "iOS Release black-box runner permits app test mutation" >&2; exit 1; }
for selector in \
  internet-source-wireguard \
  exit-dns-mode-automatic \
  exit-dns-mode-encrypted \
  exit-dns-provider-cloudflare \
  exit-dns-provider-quad9 \
  exit-dns-provider-custom \
  exit-dns-mode-through-exit \
  internet-source-direct \
  vpn-toggle
do
  grep -Fq "\"$selector\"" "$ios_release_ui" "$ios_release_ui_support" \
    || { echo "iOS Release runner omits shipped selector $selector" >&2; exit 1; }
done
grep -Fq 'assertPayloadRecovery(' "$ios_release_underlay" \
  && grep -Fq '_PAYLOAD_RECOVERY_MS=' "$ios_release_underlay" \
  && grep -Fq 'NVPN_IOS_RELEASE_BACKGROUND_' "$ios_release_ui" \
  && grep -Fq 'NVPN_IOS_RELEASE_CONNECTED_DIRECT_PASSED=1' "$ios_release_ui" \
  && grep -Fq 'requireUDPEcho' "$ios_release_probe" \
  || { echo "iOS Release runner omits underlay/lifecycle/Direct packet proof" >&2; exit 1; }
if grep -Fq -- '--nvpn-debug-' \
  "$ios_release_gate" "$ios_release_ui" "$ios_release_ui_support" "$ios_release_underlay"
then
  echo "iOS Release black-box path contains a debug app action" >&2
  exit 1
fi
if grep -Fq 'DeviceDebug' "$ios_release_gate"; then
  echo "iOS Release black-box path uses the debug configuration" >&2
  exit 1
fi
grep -Fq 'IOS_CLEANUP_ARMED=1' "$gate" \
  || { echo "iOS physical DNS gate never arms emergency tunnel cleanup" >&2; exit 1; }
grep -Fq 'ios_release_network_delete_private_test_products' "$ios_release_gate" \
  && grep -Fq 'ios_release_network_assert_retained_no_secrets' "$ios_release_gate" \
  && grep -Fq 'NVPN_PRIVATE_RELEASE_SPEC_BASE64' "$ios_release_gate" \
  && grep -Fq 'rm -rf "$xcresult"' "$ios_release_gate" \
  && ! grep -Fq 'tail -n 160 "$log"' "$ios_release_gate" \
  || { echo "iOS Release runner can retain or print private xctestrun diagnostics" >&2; exit 1; }
secret_temp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-secret-scan.XXXXXX")"
trap 'rm -rf "$secret_temp"' EXIT
secret_spec="$(
  python3 - <<'PY'
import base64
import json

payload = {
    "wireGuardConfig": "[Interface]\nPrivateKey = fake-private-key-material\n",
    "underlayHomePassphrase": "",
    "underlayAlternatePassphrase": "fake-hotspot-password",
}
print(base64.b64encode(json.dumps(payload).encode()).decode())
PY
)"
printf '%s\n' '{"passed":true}' >"$secret_temp/safe.json"
# shellcheck disable=SC1090
source "$ios_release_gate"
ios_release_network_assert_retained_no_secrets \
  "$secret_spec" "$secret_temp/safe.json"
printf '%s\n' 'fake-hotspot-password' >"$secret_temp/unsafe.log"
if ios_release_network_assert_retained_no_secrets \
  "$secret_spec" "$secret_temp/unsafe.log" 2>/dev/null
then
  echo "iOS retained-artifact scan accepted a private hotspot password" >&2
  exit 1
fi
IOS_RELEASE_NETWORK_CASE_XCTESTRUN="$secret_temp/private.xctestrun"
printf '%s\n' "$secret_spec" >"$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
mkdir -p "$secret_temp/private.xcresult"
printf '%s\n' "$secret_spec" >"$secret_temp/private.log"
ios_release_network_delete_private_test_products \
  "$secret_temp/private.xcresult" "$secret_temp/private.log"
[[ ! -e "$secret_temp/private.xctestrun" \
  && ! -e "$secret_temp/private.xcresult" \
  && ! -e "$secret_temp/private.log" ]] || {
  echo "iOS private test products survived explicit cleanup" >&2
  exit 1
}
grep -Fq 'ios_release_network_disconnect_cleanup' "$gate" "$ios_release_gate" \
  || { echo "iOS physical DNS gate cannot confirm Release disconnect after failure" >&2; exit 1; }
python3 - "$gate" "$ios_release_gate" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("run_ios_case()")
end = text.index("\nDNS_CASES=", start)
body = text[start:end]
if "run_ios_release_network_case" not in body:
    raise SystemExit("iOS DNS case never enters the Release black-box runner")
if "mobile-ios-smoke.sh" in body or "run_ios_exit_dns_shipped_ui_case_gate" in body:
    raise SystemExit("iOS DNS case retains a duplicate debug/diagnostic path")
release = open(sys.argv[2], encoding="utf-8").read()
case = release[release.index("run_ios_release_network_case()"):]
if "ios_release_network_validate_markers" not in case:
    raise SystemExit("iOS Release case does not require shipped-UI persistence receipts")
if "ios_release_network_audit_artifact" not in case:
    raise SystemExit("iOS Release case does not audit the artifact it tested")
PY

grep -Fq 'run_android_direct_while_tunnel_probe' "$android_smoke" \
  || { echo "Android smoke lacks a connected split-tunnel Internet probe" >&2; exit 1; }
for release_contract in \
  android_release_require_inputs \
  verify_android_release_install \
  configure_android_release_wireguard_ui \
  configure_android_exit_dns_ui \
  run_android_release_exit_network_probe \
  run_android_release_direct_network_probe \
  run_android_release_active_vpn_lifecycle_gate
do
  grep -Fq "$release_contract" "$android_smoke" "$android_release_gate" \
    || { echo "Android Release black-box gate is missing $release_contract" >&2; exit 1; }
done
grep -Fq 'WG upstream socket fd from native runtime:' "$android_vpn_service" \
  && grep -Fq 'Physical network changed; live FIPS carriers refreshed' \
    "$android_vpn_service" \
  && grep -Fq 'android_release_pin_native_tunnel_start_count' \
    "$android_release_gate" \
  && grep -Fq 'android_release_assert_native_tunnel_unchanged' \
    "$android_release_gate" "$android_underlay" \
  || {
    echo "Android Release gate does not pin native-tunnel continuity from production logs" >&2
    exit 1
  }
grep -Fq 'android_underlay_assert_exact_rebind_after' "$android_underlay" \
  && grep -Fq 'count == expected' "$android_underlay" \
  && grep -Fq 'count > expected' "$android_underlay" \
  || {
    echo "Android underlay gate does not require exactly one native refresh per switch" >&2
    exit 1
  }
python3 - "$android_release_gate" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
wireguard_start = text.index("configure_android_release_wireguard_ui()")
wireguard_end = text.index("\nandroid_release_vpn_toggle_checked()", wireguard_start)
wireguard = text[wireguard_start:wireguard_end]
reset = wireguard.index("android_ui_reset_scroll")
selector = wireguard.index("android_ui_scroll_to resource wireguard-enabled")
checked = wireguard.index("android_ui_query resource wireguard-enabled checked")
if not reset < selector < checked:
    raise SystemExit(
        "Android Release WireGuard gate does not return to its shipped toggle"
    )
if 'android_ui_scroll_to description "WireGuard upstream off"' in wireguard:
    raise SystemExit(
        "Android Release WireGuard gate still scrolls away from its toggle"
    )

start = text.index("run_android_release_blackbox_cycle()")
body = text[start:]
for forbidden in (
    "seed_debug_config",
    "run_android_app_network_probe",
    "copy_android_runtime_state",
    "wait_for_android_runtime_state",
    "configure_android_exit_dns_debug",
):
    if forbidden in body:
        raise SystemExit(
            f"Android Release black-box cycle uses forbidden debug helper {forbidden}"
        )
for required in (
    "configure_android_release_wireguard_ui",
    "configure_android_exit_dns_ui",
    "android_release_capture_native_tunnel_start_baseline",
    "android_release_connect_ui",
    "android_release_pin_native_tunnel_start_count",
    "android_release_assert_native_tunnel_unchanged",
    "run_android_release_exit_network_probe",
    "android_release_disconnect_ui",
):
    if required not in body:
        raise SystemExit(f"Android Release black-box cycle omits {required}")
baseline = body.index("android_release_capture_native_tunnel_start_baseline")
connect = body.index("android_release_connect_ui")
pin = body.index("android_release_pin_native_tunnel_start_count")
connected_direct = body.index("connected-direct")
disconnect = body.index("android_release_disconnect_ui", connect)
after_disconnect = body.index("after-disconnect", disconnect)
if not baseline < connect < pin < connected_direct < disconnect < after_disconnect:
    raise SystemExit(
        "Android native-tunnel receipt is not pinned across connect, Direct, and disconnect"
    )
PY
if grep -Fq -- '--nvpn-debug-' "$android_release_gate"; then
  echo "Android Release black-box library contains a debug app action" >&2
  exit 1
fi
grep -Fq 'run-as "$PACKAGE_NAME" true' "$android_release_gate" \
  && grep -Fq 'installedApkSha256' "$android_release_gate" \
  && grep -Fq 'EXPECTED_ANDROID_SIGNER_CERT_SHA256' "$android_release_gate" \
  && grep -Fq '"$normalized_cert_sha" != "$EXPECTED_ANDROID_SIGNER_CERT_SHA256"' "$android_release_gate" \
  && grep -Fq 'fipsDependenciesForcedRebuilt' "$android_release_gate" \
  && grep -Fq 'fipsGitTree' "$android_release_gate" \
  && grep -Fq 'NVPN_EXPECTED_FIPS_VERSION' "$android_release_gate" \
  && grep -Fq 'rglob("fips_core-*.d")' "$android_release_gate" \
  && grep -Fq 'fips_core::transport' "$android_release_gate" \
  && grep -Fq 'nvpn_force_rebuild_local_fips_target' "$ROOT/tools/run-android" \
  && grep -Fq '"$ROOT/tools/run-android" release' "$android_smoke" \
  || {
    echo "Android Release gate does not prove a non-debuggable exact installed artifact" >&2
    exit 1
  }
grep -Fq 'run_android_app_network_probe' "$android_smoke" \
  || { echo "Android smoke does not prove DNS and HTTPS from the shipped app process" >&2; exit 1; }
python3 - "$android_smoke" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("run_android_exit_network_probe()")
end = text.index("\nwait_for_secure_dns_success_after()", start)
body = text[start:end]
call = body[body.index("run_android_app_network_probe") :]
for required in ('"$DIRECT_PROBE_HOST"', '"$DIRECT_PROBE_URL"', '""'):
    if required not in call:
        raise SystemExit(
            "Android exit gate asks the deliberately VPN-excluded app UID "
            "to resolve tunnel-only DNS"
        )
PY
grep -Fq 'MobileAndroidCapturedNetworkProbe*.class' "$android_external_probe" \
  && grep -Fq '"${class_files[@]}"' "$android_external_probe" \
  || {
    echo "Android captured-network probe omits nested Java classes from its dex archive" >&2
    exit 1
  }
grep -Fq 'exitSourceIp' "$ROOT/scripts/MobileAndroidCapturedNetworkProbe.java" \
  && grep -Fq 'NVPN_ANDROID_EXPECTED_EXIT_SOURCE_IP' "$gate" \
  && grep -Fq 'exitSourceIp=$EXPECTED_EXIT_SOURCE_IP' "$android_external_probe" \
  && grep -Fq 'exitSourceIp=$EXPECTED_EXIT_SOURCE_IP' "$android_release_gate" \
  || {
    echo "Android exit gate does not externally prove the observed exit source IP" >&2
    exit 1
  }
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
  wait_for_android_exit_dns_persistence \
  assert_android_exit_dns_ui_reloaded \
  'shell am force-stop "$PACKAGE_NAME"' \
  'android_ui_query resource "$mode_selector" selected' \
  'android_ui_query resource "$provider_selector" selected' \
  'Android shipped Exit DNS restart readback passed'
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
grep -Fq 'expected_exit_source_ip' "$ios_probe_validator" \
  && grep -Fq '"expectedExitSourceIp": expected_source' "$gate" \
  && grep -Fq 'expected: spec.expectedExitSourceIp' "$ios_release_ui" \
  || { echo "iOS exit gate does not externally prove the observed exit source IP" >&2; exit 1; }
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
grep -Fq 'VPN lifecycle release probe finished' "$ios_debug_automation" \
  || { echo "iOS app does not acknowledge the final post-lifecycle release receipt" >&2; exit 1; }
grep -Fq 'VPN lifecycle release probe finished' "$ios_lifecycle_ui" \
  || { echo "iOS lifecycle XCTest can tear down before the final release receipt" >&2; exit 1; }
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
        "body": "203.0.113.8\n",
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
                "body": "203.0.113.8\n",
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
        "203.0.113.8",
    ]
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise SystemExit(f"valid iOS UDP echo receipt failed: {completed.stderr}")
    validated = json.loads(summary.read_text(encoding="utf-8"))
    if validated.get("replyPackets") != 4 or validated.get("replyObserved") is not True:
        raise SystemExit(f"iOS UDP echo summary lost reply evidence: {validated!r}")

    receipt["activeTunnelLifecycleCycleResults"][1]["body"] = "198.51.100.7\n"
    result.write_text(json.dumps(receipt), encoding="utf-8")
    completed = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if completed.returncode == 0:
        raise SystemExit("iOS packet validator accepted the wrong post-foreground exit IP")
    if "activeLifecycleCycle[2].exitSourceIp" not in completed.stderr:
        raise SystemExit("iOS packet validator did not identify the wrong exit source")
    receipt["activeTunnelLifecycleCycleResults"][1]["body"] = "203.0.113.8\n"

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
grep -Fq 'nvpn-wg-doh-google' "$server" \
  && grep -Fq 'nvpn-wg-dns-profile' "$server" \
  && grep -Fq 'nvpn-wg-dns-through' "$server" \
  && grep -Fq 'nvpn-wg-dns-forward' "$server" \
  || { echo "WireGuard fixture lacks distinct custom/profile/through counters" >&2; exit 1; }
grep -Fq 'counter name dns_profile' "$remote_native" \
  && grep -Fq 'counter name dns_through' "$remote_native" \
  && grep -Fq 'counter name doh_google' "$remote_native" \
  && grep -Fq 'counter name dns_forward' "$remote_native" \
  && grep -Fq 'profile-dns-count' "$remote_native" \
  && grep -Fq 'through-dns-count' "$remote_native" \
  && grep -Fq 'forward-dns-count' "$remote_native" \
  || { echo "native fixture lacks distinct custom/profile/through counters" >&2; exit 1; }

echo "mobile WireGuard exit DNS source contract passed"
