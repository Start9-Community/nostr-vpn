#!/usr/bin/env bash
# Runs both halves of manual join through the shipped nvpn command surface:
# the joiner records the admin/network pair, then the admin adds that exact
# joiner's Device ID. The resulting persisted rosters are checked independently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-manual-join-cli-e2e.XXXXXX")"
ADMIN_CONFIG="$TMP_ROOT/admin.toml"
JOINER_CONFIG="$TMP_ROOT/joiner.toml"
SEED_CONFIG="$TMP_ROOT/seed.toml"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}" \
  cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p nvpn --bin nvpn
TARGET_DIR="$(CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}" \
  cargo metadata --manifest-path "$ROOT/Cargo.toml" --no-deps --format-version 1 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
NVPN="$TARGET_DIR/debug/nvpn"

"$NVPN" init --config "$SEED_CONFIG" --force >/dev/null
SEED_DEVICE_ID="$("$NVPN" status --config "$SEED_CONFIG" --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["device_id"])')"
"$NVPN" init --config "$ADMIN_CONFIG" --force --device "$SEED_DEVICE_ID" >/dev/null
"$NVPN" init --config "$JOINER_CONFIG" --force >/dev/null
ADMIN_STATUS="$("$NVPN" status --config "$ADMIN_CONFIG" --json)"
ADMIN_DEVICE_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["device_id"])' <<<"$ADMIN_STATUS")"
NETWORK_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["network_id"])' <<<"$ADMIN_STATUS")"

JOIN_RESULT="$("$NVPN" join-manual \
  --admin-device-id "$ADMIN_DEVICE_ID" \
  --network-id "$NETWORK_ID" \
  --config "$JOINER_CONFIG" \
  --json)"
JOINER_DEVICE_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["device_id"])' <<<"$JOIN_RESULT")"

ADD_RESULT="$("$NVPN" add-device \
  --device "$JOINER_DEVICE_ID" \
  --config "$ADMIN_CONFIG" \
  --json)"

ADD_RESULT_JSON="$ADD_RESULT" python3 - "$NETWORK_ID" "$ADMIN_DEVICE_ID" "$JOINER_DEVICE_ID" \
  "$JOINER_CONFIG" "$ADMIN_CONFIG" "$NVPN" <<'PY'
import json
import os
import subprocess
import sys

network_id, admin_id, joiner_id, joiner_config, admin_config, nvpn = sys.argv[1:]
admin_edit = json.loads(os.environ["ADD_RESULT_JSON"])
joiner = json.loads(
    subprocess.check_output(
        [nvpn, "status", "--config", joiner_config, "--json"],
        text=True,
    )
)
admin = json.loads(
    subprocess.check_output(
        [nvpn, "status", "--config", admin_config, "--json"],
        text=True,
    )
)

if joiner["network_id"] != network_id:
    raise SystemExit("joiner did not persist the exact manual Network ID")
if joiner["device_id"] != joiner_id:
    raise SystemExit("joiner identity changed after manual join")
if admin["network_id"] != network_id:
    raise SystemExit("admin active network changed during manual add")
if len(admin_edit["changed"]) != 1:
    raise SystemExit("admin command did not report exactly one manual roster edit")
normalized_joiner_id = admin_edit["changed"][0]
if normalized_joiner_id not in admin_edit["participants"]:
    raise SystemExit("admin did not persist the normalized manual joiner's Device ID")
if admin_id == joiner_id:
    raise SystemExit("manual join fixture did not create distinct identities")
PY

printf 'CLI manual join passed through real joiner and admin commands.\n'
