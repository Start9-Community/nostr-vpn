#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-qr-marker.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
xcrun swiftc \
  "$ROOT/ios/Sources/QRImageImportTestMarker.swift" \
  "$ROOT/ios/MarkerTests/QRImageImportTestMarkerTests.swift" \
  -o "$TMP_ROOT/marker-tests"
"$TMP_ROOT/marker-tests"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
PRIVATE_DIR="$TMP_ROOT/private"
RELEASE_JOIN_IOS_UDID="fixture-device"
RELEASE_JOIN_IOS_APP_PATH="$TMP_ROOT/Nostr VPN.app"
remote_marker="$TMP_ROOT/device-group/nvpn-release-join-qr-image-import"
mkdir -p \
  "$PRIVATE_DIR" "$RELEASE_JOIN_IOS_APP_PATH" \
  "$(dirname "$remote_marker")"
: >"$remote_marker"
plutil -create xml1 "$RELEASE_JOIN_IOS_APP_PATH/Info.plist"
plutil -insert NVPNAppGroupIdentifier -string group.fixture.frozen \
  "$RELEASE_JOIN_IOS_APP_PATH/Info.plist"
calls=0 valid_calls=0 invalid_calls=0
xcrun() {
  [[ "$#" -eq 15 && "$1 $2 $3 $4" == "devicectl device copy to" \
    && "$5 $6" == "--device fixture-device" \
    && "$7 $8" == "--domain-type appGroupDataContainer" \
    && "$9 ${10}" == "--domain-identifier group.fixture.frozen" \
    && "${11}" == --source \
    && "${13} ${14}" == "--destination nvpn-release-join-qr-image-import" \
    && "${15}" == --quiet ]] || return 1
  [[ -f "$remote_marker" ]] || return 1
  cp "${12}" "$remote_marker"
  calls=$((calls + 1))
  if [[ "$(sed -n '1p' "${12}")" == invalid ]]; then
    invalid_calls=$((invalid_calls + 1))
  else
    [[ "$(sed -n '1p' "${12}")" == nvpn-release-join-qr-image-import-v1 \
      && "$(sed -n '2p' "${12}")" =~ ^[0-9]+$ \
      && "$(sed -n '3p' "${12}")" =~ ^[0-9a-f-]{36}$ ]] || return 1
    valid_calls=$((valid_calls + 1))
  fi
}
release_join_ios_prepare_target_app testCreateAdminNetworkAndReportPublicValues
[[ "$calls" -eq 0 ]] || { echo "ordinary test staged QR capability" >&2; exit 1; }
release_join_ios_prepare_target_app testImportJoinQrImageAndRequireAdminRosterProgress
release_join_ios_cleanup_qr_import_marker
[[ "$calls" -eq 2 && "$valid_calls" -eq 1 && "$invalid_calls" -eq 1 \
  && "$RELEASE_JOIN_IOS_QR_IMPORT_MARKER_ARMED" -eq 0 \
  && "$(sed -n '1p' "$remote_marker")" == invalid ]] \
  || { echo "QR import marker staging/cleanup contract failed" >&2; exit 1; }
echo "iOS QR image import marker tests passed"
