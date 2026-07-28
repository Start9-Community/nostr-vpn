#!/usr/bin/env bash

# Ordinary developer release-gate runs may auto-detect expensive physical and
# isolated-VM fixtures. A complete release run may not: convert every real
# network auto mode to required, and reject explicit attempts to disable one.

release_gate_require_real_network_mode() {
  local name="$1"
  local value="${!name:-auto}"
  case "$value" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Complete release gate cannot disable $name." >&2
      return 1
      ;;
    auto|AUTO|Auto|"")
      printf -v "$name" '%s' required
      export "$name"
      ;;
  esac
}

release_gate_enforce_complete_real_network_modes() {
  case "${NVPN_RELEASE_GATE_REQUIRE_COMPLETE:-0}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|"")
      return 0
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
    *)
      echo "NVPN_RELEASE_GATE_REQUIRE_COMPLETE must be a boolean." >&2
      return 2
      ;;
  esac

  local name
  for name in \
    NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E \
    NVPN_RELEASE_GATE_WINDOWS_UNDERLAY_NETWORK_CHANGE_E2E \
    NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E \
    NVPN_RELEASE_GATE_LINUX_UNDERLAY_NETWORK_CHANGE_E2E \
    NVPN_RELEASE_GATE_MOBILE_WG_EXIT_E2E \
    NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E
  do
    release_gate_require_real_network_mode "$name" || return
  done
}
