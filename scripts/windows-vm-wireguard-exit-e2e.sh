#!/usr/bin/env bash
# Run the native Windows WG-exit tests on an SSH-reachable disposable VM.
#
# With the configured remote Linux fixture this creates a one-use WireGuard
# exit, DNS resolver, and NAT gateway without provider credentials. An external
# profile remains supported through NVPN_WINDOWS_WG_EXIT_CONFIG_FILE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-wireguard-fixture.sh"

load_release_env "$ROOT"
load_mobile_env "$ROOT"

SSH_HOST="${NVPN_WINDOWS_SSH_HOST:-${1:-win11-dev}}"
SSH_JUMP="${NVPN_WINDOWS_SSH_JUMP:-}"
SSH_PROXY_COMMAND="${NVPN_WINDOWS_SSH_PROXY_COMMAND:-}"
GUEST_REPO="${NVPN_WINDOWS_GUEST_REPO_PATH:-C:\\src\\nostr-vpn}"
GUEST_CONFIG="${NVPN_WINDOWS_E2E_CONFIG:-C:\\ProgramData\\Nostr VPN\\config.toml}"
GUEST_ARTIFACT_ROOT="${GUEST_ARTIFACT_ROOT:-C:\\src\\nostr-vpn\\artifacts}"
GUEST_BINARY="${NVPN_WINDOWS_EXACT_CLI_PATH:-$GUEST_REPO\\windows\\NostrVpn.Windows\\bin\\Release\\net8.0-windows\\win-x64\\publish\\nvpn.exe}"
GUEST_INSTALLER_RECEIPT="${NVPN_WINDOWS_INSTALLER_RECEIPT_PATH:-$GUEST_ARTIFACT_ROOT\\windows-installer-gate\\installer-receipt.json}"
HOST_INSTALLER_RECEIPT="${NVPN_WINDOWS_HOST_INSTALLER_RECEIPT_PATH:?set NVPN_WINDOWS_HOST_INSTALLER_RECEIPT_PATH to the host-copied installer receipt}"
PROVIDER_CONFIG="${NVPN_WINDOWS_WG_EXIT_CONFIG_FILE:-${NVPN_WG_EXIT_CONFIG_FILE:-}}"
REQUIRE_PROVIDER_E2E="${NVPN_WINDOWS_REQUIRE_WG_DIRECT_E2E:-0}"
PROBE_URL="${NVPN_WINDOWS_E2E_INTERNET_URL:-https://example.com/}"
SOURCE_IP_URL="${NVPN_WINDOWS_E2E_SOURCE_IP_URL:-https://api.ipify.org}"
WAIT_SECS="${NVPN_WINDOWS_E2E_WAIT_SECS:-60}"
SETTLE_SECS="${NVPN_WINDOWS_E2E_SETTLE_SECS:-3}"
REMOTE_PROVIDER_CONFIG=""
REMOTE_DIRECT_STATE=""
REMOTE_SERVICE_OWNED=0
WIREGUARD_INTERFACE="nvpn-wg-exit"
FIXTURE_HOST="${NVPN_WINDOWS_WG_FIXTURE_HOST_IP:-}"
HOST_PORT="${NVPN_WINDOWS_WG_FIXTURE_PORT:-51893}"
TUNNEL_SERVER_IP="${NVPN_WINDOWS_WG_SERVER_IP:-10.99.89.1}"
TUNNEL_CLIENT_IP="${NVPN_WINDOWS_WG_CLIENT_IP:-10.99.89.2}"
THROUGH_DNS_IP="${NVPN_WINDOWS_WG_THROUGH_DNS_IP:-10.99.89.53}"
DNS_NAME="${NVPN_WINDOWS_WG_DNS_NAME:-windows-wireguard-exit.nvpn-e2e.test}"
HTTP_PROBE_PORT="${NVPN_WINDOWS_WG_HTTP_PROBE_PORT:-$HOST_PORT}"
HTTP_PROBE_TOKEN="${NVPN_WINDOWS_WG_HTTP_TOKEN:-nvpn-windows-$PPID-$$-$RANDOM}"
IMAGE="${NVPN_WINDOWS_WG_FIXTURE_IMAGE:-nostr-vpn-windows-wireguard-exit-e2e}"
CONTAINER="${NVPN_WINDOWS_WG_FIXTURE_CONTAINER:-nostr-vpn-windows-wireguard-exit-e2e-$$}"
FIXTURE_DIR=""
FIXTURE_ACTIVE=0
FIXTURE_INITIALIZED=0
EXPECTED_EXIT_SOURCE_IP=""
EXPECTED_DNS_IP=""
DNS_PROBE_NAME=""
ENDPOINT_HOST=""
WG_BEFORE=""
FORWARD_BEFORE=""
DNS_BEFORE=""

ps_quote() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

ssh_command() {
  SSH_CMD=(ssh -o BatchMode=yes)
  if [[ -n "$SSH_PROXY_COMMAND" ]]; then
    SSH_CMD+=(-o "ProxyCommand=$SSH_PROXY_COMMAND")
  elif [[ -n "$SSH_JUMP" ]]; then
    SSH_CMD+=(-J "$SSH_JUMP")
  fi
  SSH_CMD+=("$SSH_HOST")
}

scp_command() {
  SCP_CMD=(scp -q -o BatchMode=yes)
  if [[ -n "$SSH_PROXY_COMMAND" ]]; then
    SCP_CMD+=(-o "ProxyCommand=$SSH_PROXY_COMMAND")
  elif [[ -n "$SSH_JUMP" ]]; then
    SCP_CMD+=(-J "$SSH_JUMP")
  fi
}

run_ps() {
  local script="$1"
  local encoded
  encoded="$(printf '%s' "$script" | iconv -t UTF-16LE | base64 | tr -d '\n')"
  ssh_command
  "${SSH_CMD[@]}" powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -EncodedCommand "$encoded"
}

copy_to_guest() {
  local source="$1"
  local destination="$2"
  scp_command
  "${SCP_CMD[@]}" "$source" "${SSH_HOST}:${destination//\\//}"
}

capture_fixture_failure_evidence() {
  [[ "$FIXTURE_ACTIVE" -eq 1 ]] || return 0
  printf 'fixture_wg_bytes=%s -> %s\n' "$WG_BEFORE" \
    "$(mobile_wg_fixture_wg_bytes "$CONTAINER" 2>/dev/null || echo unavailable)"
  printf 'fixture_forward_packets=%s -> %s\n' "$FORWARD_BEFORE" \
    "$(mobile_wg_fixture_forward_packets "$CONTAINER" 2>/dev/null || echo unavailable)"
  printf 'fixture_dns_queries=%s -> %s\n' "$DNS_BEFORE" \
    "$(mobile_wg_fixture_dns_count "$CONTAINER" "$DNS_PROBE_NAME" 2>/dev/null || echo unavailable)"
  mobile_wg_remote_exec sudo -n env \
    "PATH=$MOBILE_WG_FIXTURE_REMOTE_PATH" \
    wg show "$MOBILE_WG_FIXTURE_REMOTE_INTERFACE" 2>&1 || true
  mobile_wg_fixture_logs "$CONTAINER" 2>&1 || true
}

provider_e2e_required() {
  case "$REQUIRE_PROVIDER_E2E" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
    0|false|FALSE|False|no|NO|No|off|OFF|Off|"") return 1 ;;
    *)
      echo "Unsupported NVPN_WINDOWS_REQUIRE_WG_DIRECT_E2E=$REQUIRE_PROVIDER_E2E" >&2
      exit 2
      ;;
  esac
}

cleanup_remote_provider_config() {
  if [[ -z "$REMOTE_PROVIDER_CONFIG" ]]; then
    return
  fi
  run_ps "Remove-Item -Force -LiteralPath $(ps_quote "$REMOTE_PROVIDER_CONFIG") -ErrorAction SilentlyContinue" \
    >/dev/null 2>&1 || true
}

cleanup_remote_service() {
  [[ "$REMOTE_SERVICE_OWNED" -eq 1 ]] || return 0
  [[ -n "${GUEST_BINARY:-}" ]] || {
    echo "Windows cleanup lost the exact candidate binary path" >&2
    return 1
  }
  if ! run_ps "\$ErrorActionPreference = 'Stop'
\$Bin = $(ps_quote "$GUEST_BINARY")
\$Config = $(ps_quote "$GUEST_CONFIG")
\$StatePath = $(ps_quote "$REMOTE_DIRECT_STATE")
\$WireGuardInterface = $(ps_quote "$WIREGUARD_INTERFACE")
\$EndpointHost = $(ps_quote "$ENDPOINT_HOST")
\$LifecycleLibrary = Join-Path $(ps_quote "$GUEST_REPO") 'scripts\\e2e-windows-wireguard-direct.lib.ps1'
if (!(Test-Path -LiteralPath \$Bin -PathType Leaf)) {
  throw \"exact Windows cleanup binary is missing: \$Bin\"
}
if (
  [string]::IsNullOrWhiteSpace(\$StatePath) -or
  !(Test-Path -LiteralPath \$StatePath -PathType Leaf)
) {
  throw 'owned Windows WireGuard cleanup lost its Direct baseline'
}
if (!(Test-Path -LiteralPath \$LifecycleLibrary -PathType Leaf)) {
  throw 'canonical Windows WireGuard cleanup library is missing'
}
. \$LifecycleLibrary
Invoke-WindowsWireGuardDirectCleanup -Binary \$Bin -Config \$Config -StatePath \$StatePath -WireGuardInterface \$WireGuardInterface -EndpointHost \$EndpointHost -ProbeUrl $(ps_quote "$PROBE_URL") -SourceIpUrl $(ps_quote "$SOURCE_IP_URL") -WaitSeconds 20 -AllowOwnedRepair | Out-Null
if (Get-Service -Name 'NvpnService' -ErrorAction SilentlyContinue) {
  & \$Bin service uninstall
  if (\$LASTEXITCODE -ne 0) { throw 'exact Windows service uninstall failed' }
}
\$Deadline = (Get-Date).AddSeconds(20)
do {
  \$Service = Get-Service -Name 'NvpnService' -ErrorAction SilentlyContinue
  \$Processes = @(Get-Process -Name 'nvpn' -ErrorAction SilentlyContinue)
  \$Adapters = @(
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
      Where-Object { \$_.Name -eq 'nvpn' }
  )
  if (!\$Service -and \$Processes.Count -eq 0 -and \$Adapters.Count -eq 0) { break }
  Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt \$Deadline)
\$Rules = @(
  Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object {
      \$_.DisplayName -eq 'nostr-vpn secure DNS' -or
      \$_.Comment -eq 'nostr-vpn authenticated DNS-over-HTTPS stub'
    }
)
if (
  \$Service -or
  \$Processes.Count -ne 0 -or
  \$Adapters.Count -ne 0 -or
  \$Rules.Count -ne 0
) {
  throw 'Windows release lane did not restore its service, process, adapter, and NRPT baseline'
}
\$Baseline = Read-WindowsWireGuardDirectBaseline \$StatePath \$WireGuardInterface \$EndpointHost
Assert-WindowsWireGuardDirectRestored \$Baseline \$WireGuardInterface \$EndpointHost $(ps_quote "$PROBE_URL") $(ps_quote "$SOURCE_IP_URL")
Remove-Item -Force -LiteralPath \$StatePath" >/dev/null
  then
    return 1
  fi
  REMOTE_DIRECT_STATE=""
  REMOTE_SERVICE_OWNED=0
}

cleanup() {
  local status="$?" cleanup_failed=0
  trap - EXIT INT TERM
  if ! cleanup_remote_service; then
    echo "Windows exact service/network baseline cleanup failed" >&2
    cleanup_failed=1
  fi
  if [[ -n "$REMOTE_DIRECT_STATE" && "$REMOTE_SERVICE_OWNED" -eq 0 ]]; then
    if run_ps "Remove-Item -Force -LiteralPath $(ps_quote "$REMOTE_DIRECT_STATE") -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $(ps_quote "$REMOTE_DIRECT_STATE")) { exit 1 }" \
      >/dev/null 2>&1
    then
      REMOTE_DIRECT_STATE=""
    else
      echo "Windows Direct baseline state survived cleanup" >&2
      cleanup_failed=1
    fi
  fi
  if [[ -n "$REMOTE_PROVIDER_CONFIG" ]]; then
    cleanup_remote_provider_config
    if ! run_ps "if (Test-Path -LiteralPath $(ps_quote "$REMOTE_PROVIDER_CONFIG")) { exit 1 }" \
      >/dev/null 2>&1
    then
      echo "Windows WireGuard source config survived cleanup" >&2
      cleanup_failed=1
    else
      REMOTE_PROVIDER_CONFIG=""
    fi
  fi
  if [[ "$FIXTURE_INITIALIZED" -eq 1 ]]; then
    if mobile_wg_fixture_cleanup "$CONTAINER" "$IMAGE"; then
      FIXTURE_ACTIVE=0
      FIXTURE_INITIALIZED=0
    else
      echo "Windows remote WireGuard fixture did not prove complete cleanup" >&2
      cleanup_failed=1
    fi
  fi
  if [[ -n "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
    if [[ -e "$FIXTURE_DIR" ]]; then
      echo "Windows local WireGuard fixture secrets survived cleanup" >&2
      cleanup_failed=1
    else
      FIXTURE_DIR=""
    fi
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

prepare_ephemeral_fixture() {
  [[ -n "${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}" && -n "$FIXTURE_HOST" ]] \
    || return 1
  [[ "${NVPN_MOBILE_WG_EXIT_REMOTE_MODE:-native}" == "native" ]] || {
    echo "Windows provider-independent exit requires the native remote fixture" >&2
    return 2
  }
  for command in wg python3 ssh scp; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "Windows provider-independent exit fixture requires $command" >&2
      return 2
    }
  done
  python3 - \
    "$TUNNEL_SERVER_IP" "$TUNNEL_CLIENT_IP" "$THROUGH_DNS_IP" \
    "$HOST_PORT" "$HTTP_PROBE_PORT" <<'PY'
import ipaddress
import sys

server, client, through = map(ipaddress.ip_address, sys.argv[1:4])
network = ipaddress.ip_network(f"{server}/24", strict=False)
ports = tuple(map(int, sys.argv[4:]))
if (
    any(address.version != 4 for address in (server, client, through))
    or any(address not in network for address in (client, through))
    or len({server, client, through}) != 3
    or any(port < 1 or port > 65535 for port in ports)
):
    raise SystemExit("invalid Windows WireGuard fixture network or port")
PY

  local endpoint_fields endpoint_family endpoint_authority
  endpoint_fields="$(mobile_wg_endpoint_fields "$FIXTURE_HOST" "$HOST_PORT")" \
    || {
      echo "Windows WireGuard fixture endpoint is malformed" >&2
      return 2
    }
  IFS=$'\t' read -r endpoint_family ENDPOINT_HOST endpoint_authority \
    <<<"$endpoint_fields"
  [[ "$endpoint_family" == "ipv4" ]] || {
    echo "Windows WireGuard fixture requires NVPN_WINDOWS_WG_FIXTURE_HOST_IP to be a reachable literal IPv4 address" >&2
    return 2
  }
  export NVPN_MOBILE_WG_EXIT_HOST_IP="$ENDPOINT_HOST"
  export NVPN_MOBILE_WG_EXIT_REMOTE_MODE=native

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-windows-wg-exit.XXXXXX")"
  chmod 700 "$FIXTURE_DIR"
  umask 077
  wg genkey >"$FIXTURE_DIR/server.key"
  wg pubkey <"$FIXTURE_DIR/server.key" >"$FIXTURE_DIR/server.pub"
  wg genkey >"$FIXTURE_DIR/client.key"
  wg pubkey <"$FIXTURE_DIR/client.key" >"$FIXTURE_DIR/client.pub"

  mobile_wg_fixture_initialize "$ROOT" "$FIXTURE_DIR"
  FIXTURE_INITIALIZED=1
  mobile_wg_fixture_assert_available "$CONTAINER" "$HOST_PORT"
  EXPECTED_EXIT_SOURCE_IP="$(
    mobile_wg_remote_exec curl -4fsS --max-time 8 "$SOURCE_IP_URL"
  )"
  python3 - "$EXPECTED_EXIT_SOURCE_IP" <<'PY'
import ipaddress
import sys
if ipaddress.ip_address(sys.argv[1]).version != 4:
    raise SystemExit("remote fixture returned no valid IPv4 exit source")
PY

  cat >"$FIXTURE_DIR/client.conf" <<EOF
[Interface]
PrivateKey = $(<"$FIXTURE_DIR/client.key")
Address = $TUNNEL_CLIENT_IP/32
DNS = $TUNNEL_SERVER_IP
MTU = 1280

[Peer]
PublicKey = $(<"$FIXTURE_DIR/server.pub")
Endpoint = $endpoint_authority
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 2
EOF
  PROVIDER_CONFIG="$FIXTURE_DIR/client.conf"
  EXPECTED_DNS_IP="$TUNNEL_SERVER_IP"
  DNS_PROBE_NAME="$DNS_NAME"

  mobile_wg_fixture_build "$ROOT" "$IMAGE" 0
  FIXTURE_ACTIVE=1
  mobile_wg_fixture_run "$IMAGE" "$CONTAINER" "$MOBILE_WG_FIXTURE_VOLUME_DIR"
  local ignored
  for ignored in $(seq 1 100); do
    mobile_wg_fixture_ready "$CONTAINER" >/dev/null 2>&1 && return 0
    mobile_wg_fixture_running "$CONTAINER" \
      || {
        mobile_wg_fixture_logs "$CONTAINER" >&2
        echo "Windows remote WireGuard fixture stopped during readiness" >&2
        return 1
      }
    sleep 0.1
  done
  mobile_wg_fixture_logs "$CONTAINER" >&2
  echo "Windows remote WireGuard fixture did not become ready" >&2
  return 1
}

if [[ ! "$WAIT_SECS" =~ ^[1-9][0-9]*$ || ! "$SETTLE_SECS" =~ ^[0-9]+$ ]]; then
  echo "Windows WG e2e wait/settle values must be non-negative integer seconds" >&2
  exit 2
fi
if [[ -n "$PROVIDER_CONFIG" && ! -r "$PROVIDER_CONFIG" ]]; then
  echo "NVPN_WINDOWS_WG_EXIT_CONFIG_FILE must name a readable WireGuard config" >&2
  exit 2
fi
[[ -f "$HOST_INSTALLER_RECEIPT" && -r "$HOST_INSTALLER_RECEIPT" ]] || {
  echo "host-copied Windows installer receipt is unreadable: $HOST_INSTALLER_RECEIPT" >&2
  exit 2
}
EXPECTED_INSTALLER_RECEIPT_SHA256="$(shasum -a 256 "$HOST_INSTALLER_RECEIPT" | awk '{ print $1 }')"
[[ "$EXPECTED_INSTALLER_RECEIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "host-copied Windows installer receipt has no SHA-256" >&2
  exit 2
}
if [[ -z "$PROVIDER_CONFIG" ]]; then
  if [[ -n "${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}" \
    && -n "$FIXTURE_HOST" ]]
  then
    prepare_ephemeral_fixture
  elif provider_e2e_required; then
    echo "Windows Direct/WireGuard/Direct e2e requires either the remote Linux fixture or NVPN_WINDOWS_WG_EXIT_CONFIG_FILE" >&2
    exit 2
  else
    echo "Windows provider-independent WireGuard fixture is not configured; running scoped Wintun only."
  fi
fi

EXPECTED_HEAD="${NVPN_WINDOWS_ARTIFACT_APP_GIT_SHA:-${NVPN_EXPECTED_APP_GIT_SHA:-$(git -C "$ROOT" rev-parse HEAD)}}"
EXPECTED_TREE="${NVPN_WINDOWS_ARTIFACT_APP_GIT_TREE:-${NVPN_EXPECTED_APP_GIT_TREE:-$(git -C "$ROOT" rev-parse "$EXPECTED_HEAD^{tree}")}}"
[[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$ && "$EXPECTED_TREE" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Windows WG e2e requires an exact packaged app revision and tree" >&2
  exit 2
}
case "${NVPN_WINDOWS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On)
    echo "Skipping Windows VM git sync; release-gate lane already synced the candidate."
    ;;
  *)
    NVPN_WINDOWS_GIT_SYNC_EXACT_APP_COMMIT="$EXPECTED_HEAD" \
      "$ROOT/scripts/windows-vm-git-sync.sh" "$SSH_HOST"
    ;;
esac

REMOTE_HEAD="$(
  run_ps "Set-Location $(ps_quote "$GUEST_REPO"); git rev-parse HEAD" \
    | tr -d '\r' \
    | awk '/^[0-9a-f]{40}$/ { value = $0 } END { print value }'
)"
REMOTE_TREE="$(
  run_ps "Set-Location $(ps_quote "$GUEST_REPO"); git rev-parse 'HEAD^{tree}'" \
    | tr -d '\r' \
    | awk '/^[0-9a-f]{40}$/ { value = $0 } END { print value }'
)"
[[ "$REMOTE_HEAD" == "$EXPECTED_HEAD" && "$REMOTE_TREE" == "$EXPECTED_TREE" ]] || {
  echo "Windows WG e2e checkout differs from the exact candidate tree" >&2
  exit 1
}

run_ps "\$ErrorActionPreference = 'Stop'
\$Service = Get-Service -Name 'NvpnService' -ErrorAction SilentlyContinue
\$Processes = @(Get-Process -Name 'nvpn' -ErrorAction SilentlyContinue)
\$Adapters = @(
  Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
    Where-Object { \$_.Name -eq 'nvpn' }
)
\$Rules = @(
  Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object {
      \$_.DisplayName -eq 'nostr-vpn secure DNS' -or
      \$_.Comment -eq 'nostr-vpn authenticated DNS-over-HTTPS stub'
    }
)
if (
  \$Service -or
  \$Processes.Count -ne 0 -or
  \$Adapters.Count -ne 0 -or
  \$Rules.Count -ne 0
) {
  throw 'Windows WireGuard lane requires a clean service, process, adapter, and NRPT baseline'
}"

run_ps "\$ErrorActionPreference = 'Stop'
Set-Location $(ps_quote "$GUEST_REPO")
\$Bin = $(ps_quote "$GUEST_BINARY")
\$ReceiptPath = $(ps_quote "$GUEST_INSTALLER_RECEIPT")
if (!(Test-Path -LiteralPath \$ReceiptPath -PathType Leaf)) {
  throw \"exact Windows installer receipt is missing: \$ReceiptPath\"
}
if (!(Test-Path -LiteralPath \$Bin -PathType Leaf)) {
  throw \"exact packaged nvpn.exe is missing: \$Bin\"
}
\$Receipt = Get-Content -Raw -LiteralPath \$ReceiptPath | ConvertFrom-Json
\$ReceiptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath \$ReceiptPath).Hash.ToLowerInvariant()
\$ExpectedBinarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath \$Bin).Hash
if (
  \$ReceiptHash -ne $(ps_quote "$EXPECTED_INSTALLER_RECEIPT_SHA256") -or
  \$Receipt.artifactType -ne 'exact installed Windows Release setup' -or
  \$Receipt.appGitSha -ne $(ps_quote "$EXPECTED_HEAD") -or
  \$Receipt.appGitTree -ne $(ps_quote "$EXPECTED_TREE") -or
  \$Receipt.installerInstalledAndLaunched -ne \$true -or
  \$Receipt.installedAppStayedAlive -ne \$true -or
  \$Receipt.payloads.cli.sha256 -ne \$ExpectedBinarySha256.ToLowerInvariant() -or
  [int64]\$Receipt.payloads.cli.size -ne (Get-Item -LiteralPath \$Bin).Length
) {
  throw 'Windows WG e2e CLI differs from the exact installed-and-launched installer payload'
}
Write-Host "WINDOWS_EXACT_INSTALLER_RECEIPT_SHA256=\$ReceiptHash"
\$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!\$IsAdmin) { throw 'Windows WG exit e2e requires an elevated/Admin SSH session for Wintun and route changes' }
& \$Bin wg-upstream-test --self-test --timeout-secs 15 --scoped-host 10.99.99.1 --ping-count 3
if (\$LASTEXITCODE -ne 0) { exit \$LASTEXITCODE }
Write-Host \"WINDOWS_EXACT_INSTALLER_CLI_SHA256=\$ExpectedBinarySha256\"
Write-Host 'WINDOWS_WIREGUARD_SCOPED_E2E_OK'"

if [[ -z "$PROVIDER_CONFIG" ]]; then
  echo "WINDOWS_WG_DIRECT_E2E_SKIPPED: set NVPN_WINDOWS_WG_EXIT_CONFIG_FILE for the real Internet route transition"
  echo "WINDOWS_WIREGUARD_EXIT_E2E_OK"
  exit 0
fi

REMOTE_PROVIDER_CONFIG="C:\\Windows\\Temp\\nvpn-provider-wg-e2e-$$-$RANDOM.conf"
copy_to_guest "$PROVIDER_CONFIG" "$REMOTE_PROVIDER_CONFIG"
REMOTE_DIRECT_STATE="C:\\Windows\\Temp\\nvpn-wg-direct-state-$$-$RANDOM.json"

run_ps "\$ErrorActionPreference = 'Stop'
\$LifecycleLibrary = Join-Path $(ps_quote "$GUEST_REPO") 'scripts\\e2e-windows-wireguard-direct.lib.ps1'
if (!(Test-Path -LiteralPath \$LifecycleLibrary -PathType Leaf)) {
  throw 'canonical Windows WireGuard preflight library is missing'
}
. \$LifecycleLibrary
Save-WindowsWireGuardDirectBaseline -StatePath $(ps_quote "$REMOTE_DIRECT_STATE") -WireGuardInterface $(ps_quote "$WIREGUARD_INTERFACE") -EndpointHost $(ps_quote "$ENDPOINT_HOST") -ProbeUrl $(ps_quote "$PROBE_URL") -SourceIpUrl $(ps_quote "$SOURCE_IP_URL") | Out-Null"

if [[ "$FIXTURE_ACTIVE" -eq 1 ]]; then
  WG_BEFORE="$(mobile_wg_fixture_wg_bytes "$CONTAINER" | awk '{ print ($1 + 0) + ($2 + 0) }')"
  FORWARD_BEFORE="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
  DNS_BEFORE="$(mobile_wg_fixture_dns_count "$CONTAINER" "$DNS_PROBE_NAME")"
fi

REMOTE_SERVICE_OWNED=1
if ! run_ps "\$ErrorActionPreference = 'Stop'
\$ProviderConfig = $(ps_quote "$REMOTE_PROVIDER_CONFIG")
\$Acl = New-Object System.Security.AccessControl.FileSecurity
\$Acl.SetAccessRuleProtection(\$true, \$false)
foreach (\$SidValue in @('S-1-5-18', 'S-1-5-32-544')) {
  \$Sid = [System.Security.Principal.SecurityIdentifier]::new(\$SidValue)
  \$Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    \$Sid,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    [System.Security.AccessControl.AccessControlType]::Allow
  )
  \$Acl.AddAccessRule(\$Rule)
}
Set-Acl -LiteralPath \$ProviderConfig -AclObject \$Acl
Set-Location $(ps_quote "$GUEST_REPO")
\$Bin = $(ps_quote "$GUEST_BINARY")
\$Config = $(ps_quote "$GUEST_CONFIG")
if (!(Test-Path -LiteralPath \$Config -PathType Leaf)) { throw \"nvpn config not found: \$Config\" }

try {
  # Establish Direct before replacing the service binary. The e2e script also
  # has its own finally block that returns the disposable VM to Direct.
  & \$Bin set --config \$Config '--exit-node='
  if (\$LASTEXITCODE -ne 0) { throw 'failed to establish Direct before the Windows WG e2e' }
  & \$Bin service install --force --config \$Config
  if (\$LASTEXITCODE -ne 0) { throw 'failed to install the Windows WG e2e daemon' }
  \$ExpectedBinarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath \$Bin).Hash
  \$Service = Get-CimInstance Win32_Service -Filter \"Name='NvpnService'\"
  if (!\$Service -or [int]\$Service.ProcessId -le 0) {
    throw 'exact Windows candidate service is not running'
  }
  \$Process = Get-CimInstance Win32_Process -Filter (\"ProcessId=\" + [int]\$Service.ProcessId)
  if (
    !\$Process -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath \$Process.ExecutablePath).Hash -ne
      \$ExpectedBinarySha256
  ) {
    throw 'NvpnService is not running the exact candidate binary'
  }

  powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File .\\scripts\\e2e-windows-wireguard-direct.ps1 \
    -Binary \$Bin \
    -Config \$Config \
    -WireGuardConfig \$ProviderConfig \
    -ProbeUrl $(ps_quote "$PROBE_URL") \
    -SourceIpUrl $(ps_quote "$SOURCE_IP_URL") \
    -ExpectedExitSourceIp $(ps_quote "$EXPECTED_EXIT_SOURCE_IP") \
    -DnsProbeName $(ps_quote "$DNS_PROBE_NAME") \
    -ExpectedDnsProbeIp $(ps_quote "$EXPECTED_DNS_IP") \
    -WireGuardEndpointHost $(ps_quote "$ENDPOINT_HOST") \
    -WireGuardInterface $(ps_quote "$WIREGUARD_INTERFACE") \
    -DirectStatePath $(ps_quote "$REMOTE_DIRECT_STATE") \
    -WaitSeconds $WAIT_SECS \
    -SettleSeconds $SETTLE_SECS
  if (\$LASTEXITCODE -ne 0) { throw 'Windows Direct/WireGuard/Direct e2e failed' }
}
finally {
  \$LifecycleLibrary = Join-Path $(ps_quote "$GUEST_REPO") 'scripts\\e2e-windows-wireguard-direct.lib.ps1'
  . \$LifecycleLibrary
  Invoke-WindowsWireGuardDirectCleanup -Binary \$Bin -Config \$Config -StatePath $(ps_quote "$REMOTE_DIRECT_STATE") -WireGuardInterface $(ps_quote "$WIREGUARD_INTERFACE") -EndpointHost $(ps_quote "$ENDPOINT_HOST") -ProbeUrl $(ps_quote "$PROBE_URL") -SourceIpUrl $(ps_quote "$SOURCE_IP_URL") -WaitSeconds 20 -AllowOwnedRepair | Out-Null
}"
then
  capture_fixture_failure_evidence
  echo "Windows WireGuard transition failed; evidence is above" >&2
  exit 1
fi

if [[ "$FIXTURE_ACTIVE" -eq 1 ]]; then
  WG_AFTER="$(mobile_wg_fixture_wg_bytes "$CONTAINER" | awk '{ print ($1 + 0) + ($2 + 0) }')"
  FORWARD_AFTER="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
  DNS_AFTER="$(mobile_wg_fixture_dns_count "$CONTAINER" "$DNS_PROBE_NAME")"
  [[ "$WG_BEFORE" =~ ^[0-9]+$ && "$WG_AFTER" =~ ^[0-9]+$ \
    && "$WG_AFTER" -gt "$WG_BEFORE" ]] \
    || {
      echo "Windows WireGuard fixture transfer counter did not increase" >&2
      capture_fixture_failure_evidence
      exit 1
    }
  [[ "$FORWARD_BEFORE" =~ ^[0-9]+$ && "$FORWARD_AFTER" =~ ^[0-9]+$ \
    && "$FORWARD_AFTER" -gt "$FORWARD_BEFORE" ]] \
    || {
      echo "Windows WireGuard fixture Internet-forward counter did not increase" >&2
      capture_fixture_failure_evidence
      exit 1
    }
  [[ "$DNS_BEFORE" =~ ^[0-9]+$ && "$DNS_AFTER" =~ ^[0-9]+$ \
    && "$DNS_AFTER" -gt "$DNS_BEFORE" ]] \
    || {
      echo "Windows WireGuard fixture DNS query counter did not increase" >&2
      capture_fixture_failure_evidence
      exit 1
    }
  echo "WINDOWS_EPHEMERAL_WG_SOURCE_TRAFFIC_DNS_OK"
fi
echo "WINDOWS_WIREGUARD_EXIT_E2E_OK"
