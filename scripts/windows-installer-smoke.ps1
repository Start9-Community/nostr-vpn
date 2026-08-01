param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath,
  [string]$InstallDir,
  [string]$ArtifactRoot
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
if (!$ArtifactRoot) {
  $ArtifactRoot = Join-Path $Root "artifacts"
}
if (!$InstallDir) {
  $InstallDir = Join-Path $env:TEMP "nostr-vpn-installer-smoke"
}

$InstallerPath = [System.IO.Path]::GetFullPath($InstallerPath)
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)

if (!(Test-Path $InstallerPath)) {
  throw "Windows installer not found: $InstallerPath"
}

New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
Get-Process -Name NostrVpn.Windows -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue

try {
  $installArgs = @(
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/DIR=$InstallDir"
  )
  $setup = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru
  if ($setup.ExitCode -ne 0) {
    throw "Installer exited with code $($setup.ExitCode)"
  }

  $appExe = Join-Path $InstallDir "NostrVpn.Windows.exe"
  if (!(Test-Path $appExe)) {
    throw "Installed Windows app not found: $appExe"
  }

  & (Join-Path $PSScriptRoot "windows-app-launch-smoke.ps1") -AppExe $appExe -ArtifactRoot $ArtifactRoot -NoWindowRequired

  $payloadFiles = [ordered]@{
    app = [ordered]@{ File = 'NostrVpn.Windows.exe'; Path = $appExe }
    appCore = [ordered]@{
      File = 'nostr_vpn_app_core.dll'
      Path = Join-Path $InstallDir 'nostr_vpn_app_core.dll'
    }
    cli = [ordered]@{
      File = 'nvpn.exe'
      Path = Join-Path $InstallDir 'nvpn.exe'
    }
    wintun = [ordered]@{
      File = 'binaries\wintun.dll'
      Path = Join-Path $InstallDir 'binaries\wintun.dll'
    }
  }
  $installedPayloads = [ordered]@{}
  foreach ($entry in $payloadFiles.GetEnumerator()) {
    if (!(Test-Path -LiteralPath $entry.Value.Path -PathType Leaf)) {
      throw "Installed Windows payload is missing: $($entry.Value.File)"
    }
    $installedPayloads[$entry.Key] = [ordered]@{
      file = $entry.Value.File
      sha256 = (
        Get-FileHash -Algorithm SHA256 -LiteralPath $entry.Value.Path
      ).Hash.ToLowerInvariant()
      size = (Get-Item -LiteralPath $entry.Value.Path).Length
    }
  }
  $smokePath = Join-Path $ArtifactRoot 'windows-app-launch-smoke.json'
  $smokeResult = Get-Content -Raw -LiteralPath $smokePath | ConvertFrom-Json
  $smokeResult | Add-Member -NotePropertyName installedPayloads `
    -NotePropertyValue ([pscustomobject]$installedPayloads)
  $smokeResult | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 `
    -LiteralPath $smokePath
  Write-Host "WINDOWS_INSTALLER_SMOKE_OK"
} finally {
  $uninstaller = Join-Path $InstallDir "unins000.exe"
  if (Test-Path $uninstaller) {
    $uninstallArgs = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
    Start-Process -FilePath $uninstaller -ArgumentList $uninstallArgs -Wait -ErrorAction SilentlyContinue | Out-Null
  }
}
