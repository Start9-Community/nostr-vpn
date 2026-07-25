#!/usr/bin/env bash
# Build the native Linux candidate, temporarily remove the VM's existing
# service registration, run the real PolicyKit UI gate, and restore it exactly.
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

  backup=\$(mktemp)
  had_unit=0
  was_active=0
  was_enabled=0
  unit_mode=
  unit_uid=
  unit_gid=
  if [[ -f /etc/systemd/system/nvpn.service ]]; then
    sudo -n cat /etc/systemd/system/nvpn.service >\"\$backup\"
    unit_mode=\$(stat -c %a /etc/systemd/system/nvpn.service)
    unit_uid=\$(stat -c %u /etc/systemd/system/nvpn.service)
    unit_gid=\$(stat -c %g /etc/systemd/system/nvpn.service)
    had_unit=1
    systemctl is-active --quiet nvpn.service && was_active=1 || true
    systemctl is-enabled --quiet nvpn.service && was_enabled=1 || true
  fi
  restore_service() {
    status=\$?
    trap - EXIT
    restore_status=0
    set +e
    if [[ \"\$had_unit\" == 1 ]]; then
      sudo -n cp \"\$backup\" /etc/systemd/system/nvpn.service
      sudo -n chown \"\$unit_uid:\$unit_gid\" /etc/systemd/system/nvpn.service
      sudo -n chmod \"\$unit_mode\" /etc/systemd/system/nvpn.service
      sudo -n systemctl daemon-reload
      [[ \"\$was_enabled\" == 1 ]] && sudo -n systemctl enable nvpn.service >/dev/null
      [[ \"\$was_active\" == 1 ]] && sudo -n systemctl start nvpn.service
      sudo -n cmp -s \"\$backup\" /etc/systemd/system/nvpn.service || restore_status=1
      [[ \"\$(stat -c %a /etc/systemd/system/nvpn.service)\" == \"\$unit_mode\" ]] \
        || restore_status=1
      [[ \"\$(stat -c %u /etc/systemd/system/nvpn.service)\" == \"\$unit_uid\" ]] \
        || restore_status=1
      [[ \"\$(stat -c %g /etc/systemd/system/nvpn.service)\" == \"\$unit_gid\" ]] \
        || restore_status=1
      current_enabled=0
      current_active=0
      systemctl is-enabled --quiet nvpn.service && current_enabled=1
      systemctl is-active --quiet nvpn.service && current_active=1
      [[ \"\$current_enabled\" == \"\$was_enabled\" ]] || restore_status=1
      [[ \"\$current_active\" == \"\$was_active\" ]] || restore_status=1
    else
      sudo -n systemctl stop nvpn.service >/dev/null 2>&1 || true
      sudo -n systemctl disable nvpn.service >/dev/null 2>&1 || true
      sudo -n rm -f /etc/systemd/system/nvpn.service
      sudo -n systemctl daemon-reload
      systemctl show nvpn.service --property=LoadState --value 2>/dev/null \
        | grep -qx not-found || restore_status=1
    fi
    rm -f \"\$backup\"
    if [[ \"\$restore_status\" != 0 ]]; then
      echo 'Failed to restore the pre-gate nvpn.service state.' >&2
      exit \"\$restore_status\"
    fi
    exit \"\$status\"
  }
  trap restore_service EXIT

  if [[ \"\$had_unit\" == 1 ]]; then
    sudo -n systemctl stop nvpn.service
    sudo -n systemctl disable nvpn.service >/dev/null 2>&1 || true
    sudo -n rm -f /etc/systemd/system/nvpn.service
    sudo -n systemctl daemon-reload
  fi
  env \
    NVPN_LINUX_CARGO_TARGET_DIR=\"\$PWD/linux/target\" \
    ./scripts/e2e-linux-service-toggle-real.sh
"
echo "UBUNTU_VM_SERVICE_TOGGLE_E2E_OK"
