#!/usr/bin/env bash
# Execute one public-GTK desktop/mobile join action on the Ubuntu VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
ARTIFACT_ROOT="${2:-}"
APP="${3:-}"
CLI="${4:-}"
RECEIPT="${5:-}"
shift $(( $# >= 5 ? 5 : $# ))

usage() {
  echo "usage: $0 <Reset|Bootstrap|CreateAdmin|AdminAdd|ManualJoin|Verify|ReadMarker|ReadReceipt|Stop|NowMs|Cleanup> <artifact-root> <app> <cli> <receipt> [arguments]" >&2
  exit 2
}

case "$MODE" in
  Reset|Bootstrap|CreateAdmin|AdminAdd|ManualJoin|Verify|ReadMarker|ReadReceipt|Stop|NowMs|Cleanup) ;;
  *) usage ;;
esac
[[ "$ARTIFACT_ROOT" == /tmp/nvpn-linux-vm-release.*/* ]] || {
  echo "Linux desktop/mobile join requires the unique imported artifact root" >&2
  exit 2
}
[[ "$APP" == /tmp/nvpn-linux-vm-release.*/nostr-vpn \
  && "$CLI" == /tmp/nvpn-linux-vm-release.*/nvpn \
  && "$RECEIPT" == /tmp/nvpn-linux-vm-release.*/receipt.json ]] || {
  echo "Linux desktop/mobile join refuses non-imported executables" >&2
  exit 2
}
[[ -x "$APP" && ! -L "$APP" && -x "$CLI" && ! -L "$CLI" \
  && -f "$RECEIPT" && ! -L "$RECEIPT" ]] || {
  echo "Linux desktop/mobile join imported artifact set is incomplete" >&2
  exit 2
}

MARKER="$ARTIFACT_ROOT/action.json"
STOP_PATH="$ARTIFACT_ROOT/stop"
DRIVER="$ROOT/scripts/desktop-mobile-manual-join-atspi.py"

assert_imported_artifacts() {
  local app_hash cli_hash
  app_hash="$(jq -er '.artifacts.app.sha256' "$RECEIPT")"
  cli_hash="$(jq -er '.artifacts.cli.sha256' "$RECEIPT")"
  [[ "$app_hash" =~ ^[0-9a-f]{64}$ \
    && "$cli_hash" =~ ^[0-9a-f]{64}$ \
    && "$(sha256sum "$APP" | awk '{ print $1 }')" == "$app_hash" \
    && "$(sha256sum "$CLI" | awk '{ print $1 }')" == "$cli_hash" \
    && "$(jq -er '.dockerPlatform' "$RECEIPT")" == linux/amd64 ]] || {
    echo "Linux desktop/mobile imported artifact receipt did not verify" >&2
    return 1
  }
  jq -e '
    .schema == 2
    and (
      (
        .builderMode == "local-docker"
        and .builtOnHostMac == true
        and .builtOnRemoteVm == false
        and .builderHostOs == "Darwin"
        and (
          .builderHostArchitecture == "arm64"
          or .builderHostArchitecture == "x86_64"
        )
      )
      or (
        .builderMode == "remote-native"
        and .builtOnHostMac == false
        and .builtOnRemoteVm == true
        and .builderHostOs == "Linux"
        and .builderHostArchitecture == "x86_64"
      )
    )
    and (.containerImageId | test("^sha256:[0-9a-f]{64}$"))
    and (.dockerfileSha256 | test("^[0-9a-f]{64}$"))
    and (.containerPayloadSha256 | test("^[0-9a-f]{64}$"))
  ' "$RECEIPT" >/dev/null || {
    echo "Linux desktop/mobile imported builder provenance did not verify" >&2
    return 1
  }
}

write_stop_atomically() {
  mkdir -p "$ARTIFACT_ROOT"
  local temporary="$ARTIFACT_ROOT/.stop.$$.tmp"
  printf 'stop\n' >"$temporary"
  mv -f "$temporary" "$STOP_PATH"
}

run_driver() {
  local action="$1"
  shift
  assert_imported_artifacts
  [[ -x "$DRIVER" ]] || {
    echo "Linux desktop/mobile AT-SPI driver is missing" >&2
    return 1
  }
  mkdir -p "$ARTIFACT_ROOT"
  rm -f "$MARKER" "$STOP_PATH"
  env -u NVPN_APP_DATA_DIR -u NVPN_CLI_PATH \
    GTK_A11Y=atspi \
    NO_AT_BRIDGE=0 \
    GDK_BACKEND=x11 \
    xvfb-run -a dbus-run-session -- \
    python3 "$DRIVER" "$action" \
      --app "$APP" \
      --marker "$MARKER" \
      --artifact-root "$ARTIFACT_ROOT" \
      --stop-path "$STOP_PATH" \
      "$@"
  python3 - "$MARKER" "$action" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
required = {
    "schema": 1,
    "mode": sys.argv[2],
    "publicUiOnly": True,
    "privateStateRead": False,
    "appLaunchArgumentsOrEnvironment": False,
}
for key, expected in required.items():
    if value.get(key) != expected:
        raise SystemExit(f"Linux public UI marker lacks {key}={expected!r}")
PY
}

case "$MODE" in
  Reset)
    [[ $# == 0 ]] || usage
    run_driver Reset
    ;;
  Bootstrap)
    [[ $# == 0 ]] || usage
    run_driver Bootstrap
    ;;
  CreateAdmin)
    [[ $# == 1 ]] || usage
    run_driver CreateAdmin --network-name "$1"
    ;;
  AdminAdd)
    [[ $# == 2 ]] || usage
    run_driver AdminAdd \
      --participant-npub "$1" \
      --participant-alias "$2"
    ;;
  ManualJoin)
    [[ $# == 2 ]] || usage
    run_driver ManualJoin --admin-npub "$1" --network-id "$2"
    ;;
  Verify)
    [[ $# == 1 ]] || usage
    run_driver Verify --participant-npub "$1"
    ;;
  ReadMarker)
    [[ $# == 0 && -f "$MARKER" && ! -L "$MARKER" ]] || exit 1
    cat "$MARKER"
    ;;
  ReadReceipt)
    [[ $# == 0 ]] || usage
    assert_imported_artifacts
    cat "$RECEIPT"
    ;;
  Stop)
    [[ $# == 0 ]] || usage
    write_stop_atomically
    ;;
  NowMs)
    [[ $# == 0 ]] || usage
    python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
    ;;
  Cleanup)
    [[ $# == 0 ]] || usage
    pkill -u "$(id -u)" -x nostr-vpn >/dev/null 2>&1 || true
    rm -f "$STOP_PATH"
    ;;
esac
