#!/usr/bin/env bash
# Drive every Exit DNS policy through the exact host-built GTK app, relaunch,
# and copy fail-closed public-UI receipts back to the release-gate log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_UBUNTU_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_UBUNTU_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn-release-gate"
LOCAL_ARTIFACT_DIR="${NVPN_DESKTOP_DNS_UI_ARTIFACT_DIR:-$ROOT/artifacts/desktop-dns-ui/linux}"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_UBUNTU_SSH_HOST or pass the Linux VM SSH target" >&2
  exit 2
}

# shellcheck disable=SC1091
source "$ROOT/scripts/lib-ubuntu-vm-imported-release.sh"
export NVPN_UBUNTU_IMPORT_EVIDENCE_DIR="$LOCAL_ARTIFACT_DIR/import"

cleanup() {
  local status="$?"
  trap - EXIT
  if ! ubuntu_vm_cleanup_imported_release_bundle; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

case "${NVPN_UBUNTU_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$SSH_HOST" ;;
esac
ubuntu_vm_import_release_bundle
ubuntu_vm_import_ssh_command

remote_artifact="$GUEST_REPO/artifacts/linux-exit-dns-ui"
"${NVPN_UBUNTU_IMPORT_SSH[@]}" bash -s -- \
  "$GUEST_REPO" \
  "$NVPN_UBUNTU_IMPORTED_APP" \
  "$NVPN_UBUNTU_IMPORTED_CLI" \
  "$NVPN_UBUNTU_IMPORTED_RECEIPT" \
  "$remote_artifact" <<'GUEST'
set -euo pipefail
repo="$1"
app="$2"
cli="$3"
bundle_receipt="$4"
artifact_root="$5"
case_root="/tmp/nvpn-linux-exit-dns-ui"
rm -rf "$case_root" "$artifact_root"
mkdir -p "$case_root" "$artifact_root"
cleanup() {
  local status="$?"
  trap - EXIT
  pkill -f "$app" >/dev/null 2>&1 || true
  rm -rf "$case_root"
  exit "$status"
}
trap cleanup EXIT

app_sha="$(jq -er '.appGitSha' "$bundle_receipt")"
app_tree="$(jq -er '.appGitTree' "$bundle_receipt")"
expected_app_hash="$(jq -er '.artifacts.app.sha256' "$bundle_receipt")"
expected_cli_hash="$(jq -er '.artifacts.cli.sha256' "$bundle_receipt")"
[[ "$(sha256sum "$app" | awk '{print $1}')" == "$expected_app_hash" ]]
[[ "$(sha256sum "$cli" | awk '{print $1}')" == "$expected_cli_hash" ]]

run_case() {
  local label="$1" mode="$2" provider="$3"
  local custom_url="$4" bootstrap="$5" through="$6"
  local root="$case_root/$label"
  local xdg="$root/xdg"
  local data="$xdg/nostr-vpn"
  local evidence="$artifact_root/$label.json"
  mkdir -p "$data" "$artifact_root/$label"
  "$cli" init --config "$data/config.toml"
  "$cli" set --config "$data/config.toml" --autoconnect false >/dev/null
  XDG_DATA_HOME="$xdg" \
    python3 "$repo/scripts/desktop-mobile-manual-join-atspi.py" \
      DnsPolicy \
      --app "$app" \
      --cli "$cli" \
      --marker "$evidence" \
      --artifact-root "$artifact_root/$label" \
      --case "$label" \
      --dns-mode "$mode" \
      --dns-provider "$provider" \
      --dns-custom-url "$custom_url" \
      --dns-bootstrap-ips "$bootstrap" \
      --dns-through-servers "$through" \
      --app-git-sha "$app_sha" \
      --app-git-tree "$app_tree"
}

cd "$repo"
export GDK_BACKEND=x11
export GTK_A11Y=atspi
export NO_AT_BRIDGE=0
xvfb-run -a dbus-run-session -- bash -s <<RUNS
set -euo pipefail
$(declare -f run_case)
app=$(printf '%q' "$app")
cli=$(printf '%q' "$cli")
repo=$(printf '%q' "$repo")
case_root=$(printf '%q' "$case_root")
artifact_root=$(printf '%q' "$artifact_root")
app_sha=$(printf '%q' "$app_sha")
app_tree=$(printf '%q' "$app_tree")
run_case automatic automatic cloudflare "" "" ""
run_case cloudflare encrypted cloudflare "" "" ""
run_case quad9 encrypted quad9 "" "" ""
run_case custom encrypted custom "https://dns.google/dns-query" "8.8.8.8,8.8.4.4" ""
run_case through-exit through_exit cloudflare "" "" "10.99.79.53"
RUNS

python3 - "$artifact_root" "$app_sha" "$app_tree" \
  "$expected_app_hash" "$expected_cli_hash" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
app_sha, app_tree, app_hash, cli_hash = sys.argv[2:]
expected = {
    "automatic": ("automatic", "cloudflare", "", "", ""),
    "cloudflare": ("encrypted", "cloudflare", "", "", ""),
    "quad9": ("encrypted", "quad9", "", "", ""),
    "custom": (
        "encrypted",
        "custom",
        "https://dns.google/dns-query",
        "8.8.8.8,8.8.4.4",
        "",
    ),
    "through-exit": ("through_exit", "cloudflare", "", "", "10.99.79.53"),
}
for case, values in expected.items():
    value = json.loads((root / f"{case}.json").read_text(encoding="utf-8"))
    actual = (
        value.get("exitDnsMode"),
        value.get("exitDnsDohProvider"),
        value.get("exitDnsCustomDohUrl"),
        value.get("exitDnsCustomDohBootstrapIps"),
        value.get("exitDnsThroughExitServers"),
    )
    if not (
        value.get("receiptSchema") == 1
        and value.get("platform") == "linux"
        and value.get("case") == case
        and value.get("savedViaShippedUi") is True
        and value.get("uiRestartReadback") is True
        and value.get("privateStateRead") is False
        and value.get("appGitSha") == app_sha
        and value.get("appGitTree") == app_tree
        and value.get("appExecutableSha256") == app_hash
        and value.get("cliExecutableSha256") == cli_hash
        and actual == values
    ):
        raise SystemExit(f"invalid Linux DNS UI receipt: {case}")
PY
GUEST

rm -rf "$LOCAL_ARTIFACT_DIR"
mkdir -p "$LOCAL_ARTIFACT_DIR"
ubuntu_vm_import_scp_command
"${NVPN_UBUNTU_IMPORT_SCP[@]}" -r \
  "$SSH_HOST:$remote_artifact/." "$LOCAL_ARTIFACT_DIR/"

echo "UBUNTU_VM_EXIT_DNS_UI_E2E_OK"
