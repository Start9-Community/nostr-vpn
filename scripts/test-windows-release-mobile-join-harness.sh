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
grep -Fq 'string.Equals(State, "pending"' "$MODELS" \
  || fail "Windows accepted selector is not withheld while join is pending"
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

grep -Fq 'windows-release-artifact.json' "$REMOTE" \
  || fail "Windows remote wrapper has no artifact receipt"
grep -Fq 'NostrVpn.Windows.exe' "$HOST" \
  || fail "Windows host wrapper does not select the Release app"
for artifact in nostr_vpn_app_core.dll nvpn.exe; do
  grep -Fq "$artifact" "$REMOTE" \
    || fail "Windows artifact receipt does not bind $artifact"
done
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
if grep -Fq 'desktop_manual_join_e2e_fixture' "$DRIVER" "$REMOTE" "$HOST"; then
  fail "Windows/Pixel acceptance invokes the private manual-join fixture"
fi

echo "WINDOWS_RELEASE_MOBILE_JOIN_HARNESS_OK"
