#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export NVPN_WEB_STARTOS_JOIN_ARTIFACT_DIR="${NVPN_WEB_STARTOS_JOIN_ARTIFACT_DIR:-${ARTIFACT_ROOT:-$ROOT_DIR/artifacts}/web-startos-lan-join}"
export NVPN_WEB_STARTOS_JOIN_SPEC="e2e/lan-join-runtime.spec.ts"
export NVPN_WEB_STARTOS_JOIN_LABEL="signed LAN join"

exec "$ROOT_DIR/scripts/e2e-web-startos-manual-join-docker.sh"
