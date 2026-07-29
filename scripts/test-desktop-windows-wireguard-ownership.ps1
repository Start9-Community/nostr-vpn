param(
  [string]$HelperRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$originalProgramData = $env:ProgramData
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
  "nvpn-wireguard-ownership-{0}-{1}" -f
    $PID,
    [Guid]::NewGuid().ToString("N")
)
$env:ProgramData = Join-Path $fixtureRoot "ProgramData"
$StateDir = Join-Path $fixtureRoot "state"
$CleanupJournalPath = Join-Path $StateDir "daemon.cleanup.json"
$WireGuardInterface = "nvpn-wg-exit"

. (Join-Path $HelperRoot "desktop-windows-underlay-change-e2e.lib.ps1")
. (Join-Path $HelperRoot "desktop-windows-underlay-crash-recovery.lib.ps1")

function Set-PrivateFixtureAcl {
  param(
    [string]$Path,
    [bool]$Directory
  )
  $acl = if ($Directory) {
    [Security.AccessControl.DirectorySecurity]::new()
  }
  else {
    [Security.AccessControl.FileSecurity]::new()
  }
  $acl.SetAccessRuleProtection($true, $false)
  $inheritance = if ($Directory) {
    [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
      [Security.AccessControl.InheritanceFlags]::ObjectInherit
  }
  else {
    [Security.AccessControl.InheritanceFlags]::None
  }
  foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
    $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $sid,
      [Security.AccessControl.FileSystemRights]::FullControl,
      $inheritance,
      [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule) | Out-Null
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-FixtureJournal {
  param(
    [string]$ConfigPath,
    [string]$OwnerToken,
    [int]$OwnerCount = 1
  )
  $owners = @()
  for ($index = 0; $index -lt $OwnerCount; $index++) {
    $owners += [ordered]@{
      name = $WireGuardInterface
      config_path = $ConfigPath
      wireguard_exe = "C:\Program Files\WireGuard\wireguard.exe"
      owner_token = if ($index -eq 0) {
        $OwnerToken
      }
      else {
        "$OwnerToken-extra-$index"
      }
      service_owned = $true
      config_owned = $true
    }
  }
  $json = [ordered]@{
    native_wireguard = $owners
  } | ConvertTo-Json -Depth 6
  [IO.Directory]::CreateDirectory($StateDir) | Out-Null
  [IO.File]::WriteAllText(
    $CleanupJournalPath,
    $json,
    [Text.UTF8Encoding]::new($false)
  )
}

function Reset-CurrentLayoutFixture {
  if (Test-Path -LiteralPath $env:ProgramData) {
    Remove-Item -LiteralPath $env:ProgramData -Recurse -Force
  }
  if (Test-Path -LiteralPath $StateDir) {
    Remove-Item -LiteralPath $StateDir -Recurse -Force
  }
  $ownerToken = "nvpn-test-owner"
  $configRoot = Join-Path $env:ProgramData "nostr-vpn\wireguard"
  $ownerDirectory = Join-Path $configRoot $ownerToken
  $configPath = Join-Path $ownerDirectory "$WireGuardInterface.conf"
  $markerPath = "$configPath.nvpn-owner"
  [IO.Directory]::CreateDirectory($ownerDirectory) | Out-Null
  [IO.File]::WriteAllText(
    $configPath,
    "[Interface]`nPrivateKey = fixture-only`n",
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    $markerPath,
    $ownerToken,
    [Text.UTF8Encoding]::new($false)
  )
  Set-PrivateFixtureAcl $configRoot $true
  Set-PrivateFixtureAcl $ownerDirectory $true
  Set-PrivateFixtureAcl $configPath $false
  Set-PrivateFixtureAcl $markerPath $false
  Write-FixtureJournal $configPath $ownerToken
  return [PSCustomObject]@{
    owner_token = $ownerToken
    config_root = $configRoot
    owner_directory = $ownerDirectory
    config_path = $configPath
    marker_path = $markerPath
  }
}

function Assert-Throws {
  param(
    [string]$Label,
    [scriptblock]$Action,
    [string]$MessagePattern = ""
  )
  try {
    & $Action | Out-Null
  }
  catch {
    if (
      ![string]::IsNullOrEmpty($MessagePattern) -and
      !([string]$_.Exception.Message).Contains($MessagePattern)
    ) {
      throw (
        "{0} failed for the wrong reason: {1}" -f
          $Label,
          $_.Exception.Message
      )
    }
    return
  }
  throw "$Label was accepted"
}

try {
  $current = Reset-CurrentLayoutFixture
  Read-CandidateNativeWireGuardOwnership
  Assert-NativeWireGuardSecretAcl
  if (
    $script:CandidateNativeWireGuardConfigRootPath -ne
      $current.config_root -or
    $script:CandidateNativeWireGuardOwnerDirectoryPath -ne
      $current.owner_directory -or
    $script:CandidateNativeWireGuardConfigPath -ne
      $current.config_path -or
    $script:CandidateNativeWireGuardOwnerMarkerPath -ne
      $current.marker_path
  ) {
    throw "current owner-token layout did not resolve to its exact paths"
  }

  $fixture = Reset-CurrentLayoutFixture
  $legacyPath = Join-Path $fixture.config_root "$WireGuardInterface.conf"
  Write-FixtureJournal $legacyPath $fixture.owner_token
  Assert-Throws "legacy flat config path" {
    Read-CandidateNativeWireGuardOwnership
  } "exact owner directory"

  $fixture = Reset-CurrentLayoutFixture
  $wrongOwnerPath = Join-Path (
    Join-Path $fixture.config_root "nvpn-wrong-owner"
  ) "$WireGuardInterface.conf"
  Write-FixtureJournal $wrongOwnerPath $fixture.owner_token
  Assert-Throws "wrong owner directory" {
    Read-CandidateNativeWireGuardOwnership
  } "exact owner directory"

  $fixture = Reset-CurrentLayoutFixture
  Remove-Item -LiteralPath $fixture.config_path -Force
  Assert-Throws "missing config" {
    Read-CandidateNativeWireGuardOwnership
  }

  $fixture = Reset-CurrentLayoutFixture
  Remove-Item -LiteralPath $fixture.marker_path -Force
  Assert-Throws "missing owner marker" {
    Read-CandidateNativeWireGuardOwnership
  }

  $fixture = Reset-CurrentLayoutFixture
  [IO.File]::WriteAllText(
    $fixture.marker_path,
    "nvpn-different-owner",
    [Text.UTF8Encoding]::new($false)
  )
  Assert-Throws "mismatched owner marker" {
    Read-CandidateNativeWireGuardOwnership
  } "does not match the cleanup journal"

  $fixture = Reset-CurrentLayoutFixture
  Write-FixtureJournal $fixture.config_path $fixture.owner_token 2
  Assert-Throws "multiple journal owners" {
    Read-CandidateNativeWireGuardOwnership
  } "expected exactly one journaled native WireGuard owner"

  $fixture = Reset-CurrentLayoutFixture
  $markerAcl = Get-Acl -LiteralPath $fixture.marker_path
  $markerAcl.SetAccessRuleProtection($false, $true)
  Set-Acl -LiteralPath $fixture.marker_path -AclObject $markerAcl
  Assert-Throws "inheriting secret ACL" {
    Assert-NativeWireGuardSecretAcl
  } "inherits permissions"

  Write-Output "WINDOWS_NATIVE_WIREGUARD_OWNERSHIP_HARNESS_OK"
}
finally {
  $env:ProgramData = $originalProgramData
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force `
    -ErrorAction SilentlyContinue
}
