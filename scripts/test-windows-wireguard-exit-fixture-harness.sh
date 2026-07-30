#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHESTRATOR="$ROOT/scripts/windows-vm-wireguard-exit-e2e.sh"
GUEST_GATE="$ROOT/scripts/e2e-windows-wireguard-direct.ps1"
LIFECYCLE="$ROOT/scripts/e2e-windows-wireguard-direct.lib.ps1"
RELEASE_GATE="$ROOT/scripts/release-gate.sh"

fail() {
  echo "Windows WireGuard fixture contract failed: $*" >&2
  exit 1
}

for source in \
  'source "$ROOT/scripts/release_common.sh"' \
  'source "$ROOT/scripts/mobile_env.sh"' \
  'source "$ROOT/scripts/lib-mobile-wireguard-fixture.sh"' \
  'load_mobile_env "$ROOT"' \
  'prepare_ephemeral_fixture' \
  'mobile_wg_fixture_initialize "$ROOT" "$FIXTURE_DIR"' \
  'mobile_wg_fixture_run "$IMAGE" "$CONTAINER"' \
  'mobile_wg_fixture_cleanup "$CONTAINER" "$IMAGE"'
do
  grep -Fq "$source" "$ORCHESTRATOR" \
    || fail "orchestrator lost production fixture step: $source"
done

for profile_line in \
  'Address = $TUNNEL_CLIENT_IP/32' \
  'DNS = $TUNNEL_SERVER_IP' \
  'Endpoint = $endpoint_authority' \
  'AllowedIPs = 0.0.0.0/0'
do
  grep -Fq "$profile_line" "$ORCHESTRATOR" \
    || fail "ephemeral client profile lost: $profile_line"
done

for ipv4_proof in \
  'FIXTURE_HOST="${NVPN_WINDOWS_WG_FIXTURE_HOST_IP:-}"' \
  '[[ "$endpoint_family" == "ipv4" ]]' \
  'requires NVPN_WINDOWS_WG_FIXTURE_HOST_IP to be a reachable literal IPv4 address'
do
  grep -Fq "$ipv4_proof" "$ORCHESTRATOR" \
    || fail "Windows fixture is not pinned to a literal IPv4 endpoint: $ipv4_proof"
done
if grep -Fq 'NVPN_MOBILE_WG_EXIT_HOST_IP:-' "$ORCHESTRATOR"; then
  fail "Windows fixture still falls back to the mobile IPv6-capable endpoint"
fi

for proof in \
  'EXPECTED_TREE="$(current_tree)"' \
  'Windows WG e2e checkout differs from the exact candidate tree' \
  'Get-FileHash -Algorithm SHA256 -LiteralPath \$Process.ExecutablePath' \
  'NvpnService is not running the exact candidate binary' \
  'mobile_wg_fixture_wg_bytes "$CONTAINER"' \
  'mobile_wg_fixture_forward_packets "$CONTAINER"' \
  'mobile_wg_fixture_dns_count "$CONTAINER" "$DNS_PROBE_NAME"' \
  'Windows WireGuard fixture transfer counter did not increase' \
  'Windows WireGuard fixture Internet-forward counter did not increase' \
  'Windows WireGuard fixture DNS query counter did not increase' \
  'WINDOWS_EPHEMERAL_WG_SOURCE_TRAFFIC_DNS_OK'
do
  grep -Fq "$proof" "$ORCHESTRATOR" \
    || fail "orchestrator lost exact candidate/fixture proof: $proof"
done

for cleanup_proof in \
  'Windows WireGuard source config survived cleanup' \
  'Windows remote WireGuard fixture did not prove complete cleanup' \
  'Windows local WireGuard fixture secrets survived cleanup'
do
  grep -Fq "$cleanup_proof" "$ORCHESTRATOR" \
    || fail "orchestrator lost cleanup proof: $cleanup_proof"
done

for baseline_proof in \
  'cleanup_remote_service' \
  'REMOTE_SERVICE_OWNED=1' \
  'REMOTE_DIRECT_STATE=' \
  'Save-WindowsWireGuardDirectBaseline' \
  'Invoke-WindowsWireGuardDirectCleanup' \
  'Assert-WindowsWireGuardDirectRestored' \
  'owned Windows WireGuard cleanup lost its Direct baseline' \
  'canonical Windows WireGuard cleanup library is missing' \
  'Windows Direct baseline state survived cleanup' \
  'Windows exact service/network baseline cleanup failed' \
  'Windows WireGuard lane requires a clean service, process, adapter, and NRPT baseline' \
  'Windows release lane did not restore its service, process, adapter, and NRPT baseline' \
  '& \$Bin service uninstall'
do
  grep -Fq "$baseline_proof" "$ORCHESTRATOR" \
    || fail "Windows fixture lacks fail-closed outer cleanup: $baseline_proof"
done
if grep -Fq 'Invoke-WebRequest -UseBasicParsing' "$ORCHESTRATOR"; then
  fail "owned Windows cleanup still accepts generic HTTPS without the original public source"
fi

for guest_proof in \
  'e2e-windows-wireguard-direct.lib.ps1' \
  'Get-WindowsWireGuardBestInternetRoute' \
  'Get-WindowsWireGuardPublicIpv4' \
  'Test-WindowsWireGuardExternalDns' \
  'Test-WindowsWireGuardExternalHttps' \
  'Test-WireGuardDns' \
  'public Internet did not use the real WireGuard exit source' \
  'Get-WindowsWireGuardExitDnsRules' \
  'Invoke-WindowsWireGuardDirectCleanup' \
  'WINDOWS_WG_DIRECT_E2E_OK'
do
  grep -Fq "$guest_proof" "$GUEST_GATE" \
    || fail "guest gate lost production transition proof: $guest_proof"
done

for lifecycle_proof in \
  '"WireGuardTunnel`$$WireGuardInterface"' \
  'Get-NetAdapter -Name $WireGuardInterface -IncludeHidden' \
  'Join-Path $env:ProgramData "nostr-vpn\wireguard"' \
  'Get-WindowsWireGuardEndpointRoutes $EndpointHost' \
  'Get-WindowsWireGuardNativeArtifacts' \
  '@(Get-WindowsWireGuardNativeArtifacts).Count -ne 0' \
  '@(Get-WindowsWireGuardEndpointRoutes $EndpointHost).Count -ne 0' \
  'Windows WireGuard lane requires no pre-existing native service' \
  'Stop-Service -Name $serviceName -Force' \
  '& sc.exe delete $serviceName' \
  'Remove-NetRoute -Confirm:$false' \
  'Remove-DnsClientNrptRule -Name $_.Name -Force' \
  'Remove-Item -Recurse -Force -ErrorAction Stop' \
  '[IO.FileAttributes]::ReparsePoint' \
  '[int]$route.InterfaceIndex -eq [int]$Baseline.direct_interface_index' \
  '[string]$route.NextHop -eq [string]$Baseline.direct_next_hop' \
  '$sourceIp -ne [string]$Baseline.direct_source_ip' \
  'original Direct public source was not restored' \
  '[switch]$AllowOwnedRepair'
do
  grep -Fq "$lifecycle_proof" "$LIFECYCLE" \
    || fail "canonical Windows lifecycle lost resource/restore proof: $lifecycle_proof"
done

python3 - "$GUEST_GATE" "$ORCHESTRATOR" "$LIFECYCLE" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
outer = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
lifecycle = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
direct = text.index("$directInterfaceIndex =")
wireguard = text.index('"--wireguard-exit-enabled", "true"')
restore = text.index('Invoke-Nvpn @("set", "--config", $Config, "--exit-node=")')
cleanup = text.index(
    "Invoke-WindowsWireGuardDirectCleanup", restore
)
if not direct < wireguard < restore < cleanup:
    raise SystemExit("guest transition is not ordered Direct -> WireGuard -> Direct -> cleanup")

normal_cleanup = text[cleanup : text.index("$directCleanupComplete = $true", cleanup)]
if "-AllowOwnedRepair" in normal_cleanup:
    raise SystemExit("successful product transition can hide cleanup failure with emergency repair")
finally_block = text[text.index("finally {") :]
if "-AllowOwnedRepair" not in finally_block:
    raise SystemExit("failed product transition lacks owned-resource emergency cleanup")

preflight = outer.index("Save-WindowsWireGuardDirectBaseline")
ownership = outer.index("REMOTE_SERVICE_OWNED=1")
mutation = outer.index("& \\$Bin service install --force")
if not preflight < ownership < mutation:
    raise SystemExit("outer lane does not prove a clean Direct baseline before ownership/mutation")
outer_cleanup = outer.index("cleanup_remote_service()")
outer_invoke = outer.index("Invoke-WindowsWireGuardDirectCleanup", outer_cleanup)
outer_assert = outer.index("Assert-WindowsWireGuardDirectRestored", outer_invoke)
outer_uninstall = outer.index("& \\$Bin service uninstall", outer_invoke)
if not outer_invoke < outer_uninstall < outer_assert:
    raise SystemExit(
        "outer cleanup must restore native resources, uninstall, then re-prove Direct"
    )

repair_gate = lifecycle.index("if (!$AllowOwnedRepair)")
repair_call = lifecycle.index("Repair-WindowsWireGuardOwnedResources", repair_gate)
if repair_call < repair_gate:
    raise SystemExit("emergency resource deletion is not ownership-gated")
PY

python3 - "$RELEASE_GATE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
orchestrator = "./scripts/windows-vm-wireguard-exit-e2e.sh"
required = "env NVPN_WINDOWS_REQUIRE_WG_DIRECT_E2E=1"
calls = [index for index, line in enumerate(lines) if orchestrator in line]
if len(calls) != 2:
    raise SystemExit(
        f"release gate must have exactly two Windows WireGuard call sites, got {len(calls)}"
    )
for index in calls:
    command = "\n".join(lines[max(0, index - 3) : index + 1])
    if required not in command:
        raise SystemExit(
            "release gate can invoke Windows WireGuard without forcing "
            "Direct -> WireGuard -> Direct"
        )
PY

echo "Windows provider-independent WireGuard exit fixture contract passed"
