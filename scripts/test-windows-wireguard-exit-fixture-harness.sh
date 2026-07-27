#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHESTRATOR="$ROOT/scripts/windows-vm-wireguard-exit-e2e.sh"
GUEST_GATE="$ROOT/scripts/e2e-windows-wireguard-direct.ps1"

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

for guest_proof in \
  'Get-BestInternetRoute' \
  'Get-PublicIpv4' \
  'Test-ExternalDns' \
  'Test-ExternalHttps' \
  'Test-WireGuardDns' \
  'public Internet did not use the real WireGuard exit source' \
  'Get-NvpnExitDnsRules' \
  'Get-NativeWireGuardArtifacts' \
  'Get-EndpointBypassRoutes' \
  'native WireGuard config or ownership artifact leaked after Direct' \
  'WireGuard endpoint bypass route leaked after Direct' \
  'native WireGuard service and adapter cleanup' \
  'WINDOWS_WG_DIRECT_E2E_OK'
do
  grep -Fq "$guest_proof" "$GUEST_GATE" \
    || fail "guest gate lost production transition proof: $guest_proof"
done

python3 - "$GUEST_GATE" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
direct = text.index("$directRoute = Get-BestInternetRoute")
wireguard = text.index('"--wireguard-exit-enabled", "true"')
restore = text.index('Invoke-Nvpn @("set", "--config", $Config, "--exit-node=")')
cleanup = text.index(
    'Wait-ForCondition "native WireGuard service and adapter cleanup"'
)
if not direct < wireguard < restore < cleanup:
    raise SystemExit("guest transition is not ordered Direct -> WireGuard -> Direct -> cleanup")
PY

echo "Windows provider-independent WireGuard exit fixture contract passed"
