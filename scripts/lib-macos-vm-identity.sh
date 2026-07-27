#!/usr/bin/env bash

# Fail closed before any macOS release gate syncs files, launches an app, or
# changes routes/DNS. The private expected hash identifies the disposable UTM
# guest without publishing its platform UUID.

macos_vm_identity_sha256() {
  local value="${1:-}"
  [[ "$value" =~ ^[A-Fa-f0-9-]{8,}$ ]] || {
    echo "macOS platform UUID is missing or malformed" >&2
    return 1
  }
  printf '%s' "$value" | shasum -a 256 | awk '{print tolower($1)}'
}

macos_vm_platform_uuid_from_ioreg() {
  sed -n 's/.*"IOPlatformUUID"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

macos_vm_require_isolated_target() {
  local ssh_host="${1:-}"
  local expected local_uuid remote_uuid local_identity remote_identity
  [[ -n "$ssh_host" ]] || {
    echo "macOS VM identity check requires an SSH target" >&2
    return 1
  }
  expected="$(
    printf '%s' "${NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256:-}" \
      | tr -d ':[:space:]' \
      | tr '[:upper:]' '[:lower:]'
  )"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Set NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256 to the pinned macos-utm identity hash" >&2
    return 1
  }
  local_uuid="$(
    ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
      | macos_vm_platform_uuid_from_ioreg
  )" || return 1
  remote_uuid="$(
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_host" \
      'ioreg -rd1 -c IOPlatformExpertDevice' 2>/dev/null \
      | macos_vm_platform_uuid_from_ioreg
  )" || return 1
  local_identity="$(macos_vm_identity_sha256 "$local_uuid")" || return 1
  remote_identity="$(macos_vm_identity_sha256 "$remote_uuid")" || return 1
  [[ "$remote_identity" != "$local_identity" ]] || {
    echo "Refusing macOS VM gate: SSH target is the current Mac" >&2
    return 1
  }
  [[ "$remote_identity" == "$expected" ]] || {
    echo "Refusing macOS VM gate: SSH target is not the pinned macos-utm guest" >&2
    return 1
  }
}
