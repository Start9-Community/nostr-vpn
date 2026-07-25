#!/usr/bin/env bash
# Build and drive both shipped GTK manual-join roles on an isolated Linux VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_UBUNTU_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_UBUNTU_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn-release-gate"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_UBUNTU_SSH_HOST or pass the Linux VM SSH target" >&2
  exit 2
}

case "${NVPN_UBUNTU_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$SSH_HOST" ;;
esac

ssh -o BatchMode=yes "$SSH_HOST" "
  set -euo pipefail
  cd '$GUEST_REPO'
  export CARGO_TARGET_DIR=\"\$PWD/linux/target\"
  case '${NVPN_UBUNTU_SKIP_BUILD:-0}' in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
    *)
      cargo build -q -p nvpn
      cargo build -q -p nostr-vpn-core --example desktop_manual_join_e2e_fixture
      (cd linux && cargo build -q)
      ;;
  esac
  env \
    NVPN_REPO_ROOT=\"\$PWD\" \
    NVPN_DESKTOP_MANUAL_JOIN_SKIP_BUILD=1 \
    NVPN_LINUX_CARGO_TARGET_DIR=\"\$PWD/linux/target\" \
    NVPN_ROOT_CARGO_TARGET_DIR=\"\$PWD/linux/target\" \
    xvfb-run -a dbus-run-session -- ./linux/scripts/e2e-manual-join-ui.sh
  python3 - <<'PY'
import json
from pathlib import Path

artifact = Path('artifacts/linux-manual-join-ui')
result = json.loads((artifact / 'result.json').read_text(encoding='utf-8'))
required = {
    'phase': 'runtime-verified',
    'exactSignedRosterDurablyApplied': True,
    'adminOutboxConsumedByExactJoinRosterAck': True,
    'publicFipsCrossSeedRouteOnly': True,
}
for key, expected in required.items():
    if result.get(key) != expected:
        raise SystemExit(f'Linux manual-join result lacks {key}={expected!r}')
for name in (
    'admin-daemon.log',
    'joiner-daemon.log',
    'admin-status.json',
    'joiner-status.json',
    'timings.json',
):
    if not (artifact / name).is_file():
        raise SystemExit(f'Linux manual-join artifact missing: {name}')
PY
"
echo "UBUNTU_VM_DESKTOP_MANUAL_JOIN_UI_E2E_OK"
