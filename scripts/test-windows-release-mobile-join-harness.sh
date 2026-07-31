#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XAML="$ROOT/windows/NostrVpn.Windows/MainWindow.xaml"
MODELS="$ROOT/windows/NostrVpn.Windows/Core/Models.cs"
DRIVER="$ROOT/scripts/desktop-mobile-manual-join-windows-ui.ps1"
REMOTE="$ROOT/scripts/windows-release-mobile-join-remote.ps1"
HOST="$ROOT/scripts/windows-vm-release-mobile-join-e2e.sh"

fail() {
  echo "Windows/Pixel release join harness failed: $*" >&2
  exit 1
}

for file in "$XAML" "$MODELS" "$DRIVER" "$REMOTE" "$HOST"; do
  [[ -f "$file" ]] || fail "missing $(basename "$file")"
done

for identifier in \
  ManualJoinCreateNetworkChoice \
  ManualJoinCreateNetworkName \
  ManualJoinCreateNetworkSubmit \
  ManualJoinJoinerDeviceIdValue \
  ManualJoinAdminDeviceIdValue \
  ManualJoinAdminNetworkIdValue
do
  grep -Fq "$identifier" "$XAML" \
    || fail "shipped Windows UI lacks $identifier"
done
grep -Fq 'AcceptedRosterAutomationId' "$XAML" \
  || fail "Windows roster UI does not bind its accepted-only selector"
if sed -n '/AcceptedRosterAutomationId/,/DisplayName/p' "$MODELS" \
  | grep -Fq 'State'; then
  fail "Windows roster membership selector still depends on transport state"
fi
for pending_status in 'waiting for admin' 'join request sent'; do
  sed -n '/AcceptedRosterAutomationId/,/DisplayName/p' "$MODELS" \
    | grep -Fq "$pending_status" \
    || fail "Windows selector accepts an unconfirmed $pending_status roster"
done
grep -Fq 'RosterParticipantAccepted-' "$MODELS" \
  || fail "Windows model has no dynamic accepted roster identifier"

for mode in Reset Bootstrap CreateAdmin AdminAdd ManualJoin Verify; do
  grep -Fq "\"$mode\"" "$DRIVER" \
    || fail "Windows UI driver lacks $mode"
done
grep -Fq '"RosterParticipantAccepted-$ParticipantNpub"' "$DRIVER" \
  || fail "Windows admin driver accepts a generic roster row"
grep -Fq '"RosterParticipantAccepted-$AdminNpub"' "$DRIVER" \
  || fail "Windows joiner driver accepts a generic roster row"
grep -Fq '$Evidence.relaunchAccepted = $true' "$DRIVER" \
  || fail "Windows driver lacks relaunch acceptance evidence"
grep -Fq 'publicUiOnly = $true' "$DRIVER" \
  || fail "Windows action evidence is not public-UI-only"
grep -Fq 'privateStateRead = $false' "$DRIVER" \
  || fail "Windows action evidence does not reject private readback"
for canonical_readback_contract in \
  'function ConvertTo-CanonicalIpCsv' \
  "(\$Value -split '[,\\s]+')" \
  '[System.Net.IPAddress]::TryParse' \
  'Sort-Object -Unique' \
  'ConvertTo-CanonicalIpCsv (' \
  'Read-ControlValue "ExitDnsBootstrapIps"' \
  'ConvertTo-CanonicalIpCsv $DnsBootstrapIps'
do
  grep -Fq "$canonical_readback_contract" "$DRIVER" \
    || fail "Windows custom DoH relaunch readback is not canonical IP-set evidence"
done

grep -Fq 'windows-release-artifact.json' "$REMOTE" \
  || fail "Windows remote wrapper has no artifact receipt"
grep -Fq 'NostrVpn.Windows.exe' "$HOST" \
  || fail "Windows host wrapper does not select the Release app"
for artifact in nostr_vpn_app_core.dll nvpn.exe; do
  grep -Fq "$artifact" "$REMOTE" \
    || fail "Windows artifact receipt does not bind $artifact"
done
for service_contract in \
  '$ServiceName = "NvpnService"' \
  'Get-Service -Name $ServiceName' \
  'Stop-Service -Name $ServiceName'
do
  grep -Fq "$service_contract" "$REMOTE" \
    || fail "Windows wrapper does not use the production service name"
done
if grep -Eq '(Get|Stop)-Service -Name "nvpn"' "$REMOTE"; then
  fail "Windows wrapper still queries the obsolete service name"
fi
if grep -Eq 'cargo (build|run)|dotnet (build|publish)|windows-build\\.ps1' "$REMOTE" "$HOST"; then
  fail "physical Windows/Pixel phase compiles instead of reusing Release artifacts"
fi

for evidence in \
  release_join_android_wait_accepted_participant \
  verify_desktop_relaunch \
  verify_pixel_relaunch \
  desktop_mobile_manual_join_receipt.py \
  'RELEASE_JOIN_DELIVERY_WAIT_SECS <= 15'
do
  grep -Fq "$evidence" "$HOST" \
    || fail "Windows/Pixel orchestrator lacks $evidence"
done
for component_binding in \
  --android-artifact-receipt \
  --android-fips-metadata-receipt \
  --expected-desktop-app-sha \
  --expected-android-app-sha \
  --expected-desktop-fips-sha \
  --expected-android-fips-sha
do
  grep -Fq -- "$component_binding" "$HOST" \
    || fail "Windows/Pixel receipt lacks $component_binding"
done
if grep -Fq 'desktop_manual_join_e2e_fixture' "$DRIVER" "$REMOTE" "$HOST"; then
  fail "Windows/Pixel acceptance invokes the private manual-join fixture"
fi

echo "WINDOWS_RELEASE_MOBILE_JOIN_HARNESS_OK"
