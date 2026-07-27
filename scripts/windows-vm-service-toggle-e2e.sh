#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_WINDOWS_SSH_HOST:-${1:-}}"
SSH_JUMP="${NVPN_WINDOWS_SSH_JUMP:-}"
SSH_PROXY_COMMAND="${NVPN_WINDOWS_SSH_PROXY_COMMAND:-}"
GUEST_REPO="${NVPN_WINDOWS_GUEST_REPO_PATH:-C:\\src\\nostr-vpn}"
GUEST_FIPS_REPO="${NVPN_WINDOWS_GUEST_FIPS_REPO_PATH:-C:\\src\\fips}"
GUEST_ARTIFACT_ROOT="${GUEST_ARTIFACT_ROOT:-C:\\src\\nostr-vpn\\artifacts}"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_WINDOWS_SSH_HOST or pass the Windows VM SSH target" >&2
  exit 2
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

run_ps() {
  local script="$1"
  local encoded
  encoded="$(printf '%s' "$script" | iconv -t UTF-16LE | base64 | tr -d '\n')"
  ssh_command
  "${SSH_CMD[@]}" powershell.exe -NoProfile -EncodedCommand "$encoded"
}

case "${NVPN_WINDOWS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/windows-vm-git-sync.sh" "$SSH_HOST" ;;
esac

run_ps "\$ErrorActionPreference = 'Stop'
Set-Location '$GUEST_REPO'
New-Item -ItemType Directory -Force -Path '$GUEST_ARTIFACT_ROOT' | Out-Null
if ('${NVPN_FIPS_REPO_PATH:-}' -ne '') { \$env:NVPN_FIPS_REPO_PATH = '$GUEST_FIPS_REPO' }
\$app = Join-Path '$GUEST_REPO' 'windows\\NostrVpn.Windows\\bin\\Release\\net8.0-windows\\win-x64\\publish\\NostrVpn.Windows.exe'
\$installerReceiptPath = Join-Path '$GUEST_ARTIFACT_ROOT' 'windows-installer-gate\\installer-receipt.json'
if (
  !(Test-Path -LiteralPath \$app -PathType Leaf) -or
  !(Test-Path -LiteralPath \$installerReceiptPath -PathType Leaf)
) {
  throw 'exact installed-and-launched Windows Release app receipt is missing'
}
\$installerReceipt = Get-Content -Raw -LiteralPath \$installerReceiptPath | ConvertFrom-Json
if (
  \$installerReceipt.installerInstalledAndLaunched -ne \$true -or
  (Get-FileHash -Algorithm SHA256 -LiteralPath \$app).Hash.ToLowerInvariant() -ne
    \$installerReceipt.payloads.app.sha256
) {
  throw 'Windows service-toggle app differs from the exact installer gate payload'
}
\$artifact = Join-Path '$GUEST_ARTIFACT_ROOT' 'windows-service-toggle'
\$interactiveWrapper = Join-Path '$GUEST_ARTIFACT_ROOT' 'windows-service-toggle-interactive.ps1'
@'
\$ErrorActionPreference = 'Stop'
\$env:CARGO_TARGET_DIR = '$GUEST_ARTIFACT_ROOT\\windows-ui-e2e-cargo'
& '$GUEST_REPO\\scripts\\e2e-windows-service-toggle.ps1' -AppExe '$GUEST_REPO\\windows\\NostrVpn.Windows\\bin\\Release\\net8.0-windows\\win-x64\\publish\\NostrVpn.Windows.exe' -ArtifactRoot '$GUEST_ARTIFACT_ROOT\\windows-service-toggle'
'@ | Set-Content -Encoding utf8 \$interactiveWrapper
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\run-windows-interactive-e2e.ps1 -ScriptPath \$interactiveWrapper -TimeoutSeconds 180 -CleanupConsentPrompt
if (\$LASTEXITCODE -ne 0) { throw ('interactive service-toggle e2e failed with exit code {0}' -f \$LASTEXITCODE) }
if (!(Test-Path (Join-Path \$artifact 'window.png'))) {
  throw 'Windows service-toggle UI window artifact was not created'
}"

echo "WINDOWS_VM_SERVICE_TOGGLE_E2E_OK"
