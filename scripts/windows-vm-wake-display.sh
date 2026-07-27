#!/usr/bin/env bash
set -euo pipefail

HYPERVISOR_SSH="${NVPN_DESKTOP_UNDERLAY_HYPERVISOR_SSH:-}"
VM_NAME="${NVPN_WINDOWS_UNDERLAY_VM_NAME:-${NVPN_WINDOWS_VM_NAME:-}}"

if [[ -z "$HYPERVISOR_SSH" && -z "$VM_NAME" ]]; then
  echo "Windows VM display wake skipped; no hypervisor was configured."
  exit 0
fi
[[ -n "$HYPERVISOR_SSH" && -n "$VM_NAME" ]] || {
  echo "Windows VM display wake requires both hypervisor SSH and VM name." >&2
  exit 2
}

ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- "$VM_NAME" <<'SH'
set -euo pipefail
vm="$1"
[[ "$(virsh domstate "$vm")" == "running" ]]
virsh send-key "$vm" KEY_LEFTSHIFT
SH

echo "WINDOWS_VM_DISPLAY_AWAKE"
