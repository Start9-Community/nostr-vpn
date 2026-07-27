#!/usr/bin/env bash

macos_vm_imported_release_bool() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

macos_vm_prepare_or_verify_imported_release() {
  local root="$1"
  local ssh_host="$2"
  local action="prepare-only"
  local skip_sync="${NVPN_MACOS_SKIP_GIT_SYNC:-0}"

  if macos_vm_imported_release_bool \
    "${NVPN_MACOS_IMPORTED_RELEASE_ARTIFACT_READY:-0}"
  then
    action="verify-only"
    skip_sync=1
  fi

  NVPN_MACOS_RELEASE_ARTIFACT_ACTION="$action" \
    NVPN_MACOS_SKIP_GIT_SYNC="$skip_sync" \
    "$root/scripts/macos-vm-release-mobile-join-e2e.sh" "$ssh_host"
  export NVPN_MACOS_IMPORTED_RELEASE_ARTIFACT_READY=1
}

macos_vm_imported_release_package() {
  local guest_repo="$1"
  printf '%s/artifacts/macos-release-mobile-join/imported\n' "$guest_repo"
}
