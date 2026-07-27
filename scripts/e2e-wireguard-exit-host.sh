#!/usr/bin/env bash
# Native host WG-exit dataplane smoke for macOS/Linux-style hosts.
#
# This complements the Linux Docker e2e. It uses `nvpn wg-upstream-test
# --self-test` so no external VPN account is needed: nvpn starts an in-process
# WireGuard responder, creates a real host tun/utun, installs a scoped route to
# the responder's tunnel IP, pings through the WG tunnel, then removes the route.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${NVPN_WG_EXIT_HOST_PROFILE:-debug}"
NVPN_BIN="${NVPN_WG_EXIT_HOST_BINARY:-}"
VM_IMPORT_ONLY="${NVPN_MACOS_VM_IMPORT_ONLY:-0}"
if [[ -z "$NVPN_BIN" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only WireGuard exit requires NVPN_WG_EXIT_HOST_BINARY." >&2
      exit 2
      ;;
  esac
  BUILD_ARGS=(--locked -p nvpn --bin nvpn)
  OUTPUT_ARGS=(nvpn)
  case "$PROFILE" in
    release)
      BUILD_ARGS+=(--release)
      OUTPUT_ARGS+=(--release)
      ;;
    debug)
      ;;
    *)
      echo "Unsupported NVPN_WG_EXIT_HOST_PROFILE=$PROFILE; expected debug or release" >&2
      exit 2
      ;;
  esac
  cargo build "${BUILD_ARGS[@]}"
  NVPN_BIN="$(./scripts/build-output-path --raw "${OUTPUT_ARGS[@]}")"
fi
if [[ ! -x "$NVPN_BIN" ]]; then
  echo "nvpn binary not found at $NVPN_BIN" >&2
  exit 1
fi
case "$VM_IMPORT_ONLY:$(uname -s)" in
  1:Darwin|true:Darwin|TRUE:Darwin|True:Darwin|yes:Darwin|YES:Darwin|Yes:Darwin|on:Darwin|ON:Darwin|On:Darwin)
    codesign --verify --strict "$NVPN_BIN"
    ;;
esac

TEST_ARGS=(
  wg-upstream-test
  --self-test
  --timeout-secs "${NVPN_WG_EXIT_HOST_TIMEOUT_SECS:-15}"
  --scoped-host "${NVPN_WG_EXIT_HOST_SCOPED_HOST:-10.99.99.1}"
  --ping-count "${NVPN_WG_EXIT_HOST_PING_COUNT:-3}"
)

case "$(uname -s)" in
  Darwin|Linux)
    if [[ "$(id -u)" == "0" ]]; then
      exec "$NVPN_BIN" "${TEST_ARGS[@]}"
    fi
    if [[ "${NVPN_WG_EXIT_HOST_INTERACTIVE_SUDO:-0}" =~ ^(1|true|TRUE|True|yes|YES|Yes|on|ON|On)$ ]]; then
      exec sudo "$NVPN_BIN" "${TEST_ARGS[@]}"
    fi
    # Invoke the exact privileged test command instead of probing with a broad
    # `sudo -n true`. A narrowly-scoped sudoers rule can therefore authorize
    # this path without granting unrelated passwordless commands.
    exec sudo -n "$NVPN_BIN" "${TEST_ARGS[@]}"
    ;;
  *)
    echo "WireGuard exit host e2e supports Darwin/Linux here; use scripts/windows-vm-wireguard-exit-e2e.sh for Windows." >&2
    exit 2
    ;;
esac
