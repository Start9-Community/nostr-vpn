param(
  [Parameter(Mandatory = $true)]
  [string]$AppExe,
  [Parameter(Mandatory = $true)]
  [string]$ArtifactRoot,
  [Parameter(Mandatory = $true)]
  [string]$CargoTargetDir,
  [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"
$AdminDataDir = Join-Path $ArtifactRoot "admin"
$JoinerDataDir = Join-Path $ArtifactRoot "joiner"
$Result = Join-Path $ArtifactRoot "result.json"
$Nvpn = Join-Path (Split-Path -Parent $AppExe) "nvpn.exe"
$Fixture = Join-Path $CargoTargetDir "release\examples\desktop_manual_join_e2e_fixture.exe"
$AdminConfig = Join-Path $AdminDataDir "config.toml"
$JoinerConfig = Join-Path $JoinerDataDir "config.toml"
$RuntimeStartedMs = 0L
$DeliveryStartedMs = 0L
$DeliveryFinishedMs = 0L
$RuntimeDeadline = [DateTimeOffset]::MaxValue

foreach ($Path in @($Nvpn, $Fixture, $AdminConfig, $JoinerConfig, $Result)) {
  if (!(Test-Path $Path)) {
    throw "Windows real manual-join runtime input is missing: $Path"
  }
}

function Stop-IsolatedRuntime {
  foreach ($Config in @($AdminConfig, $JoinerConfig)) {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
      & $Nvpn stop --force --timeout-secs 5 --config $Config *> $null
    } finally {
      $ErrorActionPreference = $PreviousErrorActionPreference
    }
  }
  Get-CimInstance Win32_Process -Filter "Name = 'nvpn.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and (
        $_.CommandLine.Contains($AdminConfig) -or
        $_.CommandLine.Contains($JoinerConfig)
      )
    } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Get-DefaultRouteSnapshot {
  @(
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" |
      Sort-Object InterfaceIndex, NextHop, RouteMetric |
      Select-Object InterfaceIndex, InterfaceAlias, NextHop, RouteMetric,
        PolicyStore
  ) | ConvertTo-Json -Depth 4 -Compress
}

function Get-DnsSnapshot {
  @(
    Get-DnsClientServerAddress -AddressFamily IPv4 |
      Where-Object { $_.ServerAddresses.Count -gt 0 } |
      Sort-Object InterfaceIndex |
      Select-Object InterfaceIndex, InterfaceAlias, ServerAddresses
  ) | ConvertTo-Json -Depth 4 -Compress
}

function Assert-DirectInternet {
  $Response = Invoke-WebRequest `
    -UseBasicParsing `
    -TimeoutSec 8 `
    -Uri "https://connectivitycheck.gstatic.com/generate_204"
  if ($Response.StatusCode -ne 204) {
    throw "Windows Direct Internet probe returned HTTP $($Response.StatusCode)"
  }
}

function Read-DaemonStatus {
  param([string]$Config)
  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $Raw = (& $Nvpn status --json --discover-secs 0 --config $Config 2>$null |
      Out-String)
    if ($LASTEXITCODE -ne 0) {
      return $null
    }
    return $Raw | ConvertFrom-Json
  } catch {
    return $null
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }
}

function Wait-PublicSeed {
  param(
    [string]$Config,
    [string]$ExpectedSeed,
    [string]$ExpectedUrl,
    [string]$Label
  )
  $ExpectedAddress = "websocket:$ExpectedUrl"
  while ([DateTimeOffset]::UtcNow -lt $RuntimeDeadline) {
    $Status = Read-DaemonStatus $Config
    if (
      $Status -and
      $Status.status_source -eq "daemon" -and
      $Status.daemon.running -eq $true -and
      $Status.daemon.state.vpn_enabled -eq $true -and
      $Status.daemon.state.vpn_active -eq $true -and
      $Status.daemon.state.fips_other_peer_count -ge 1
    ) {
      $Seed = @($Status.daemon.state.fips_endpoint_peers) |
        Where-Object { $_.npub -eq $ExpectedSeed } |
        Select-Object -First 1
      if ($Seed -and @($Seed.addresses | Where-Object {
        $_.addr -eq $ExpectedAddress
      }).Count -eq 1) {
        return
      }
    }
    Start-Sleep -Milliseconds 100
  }
  $Status = Read-DaemonStatus $Config
  if ($Status) {
    $Status | ConvertTo-Json -Depth 20 |
      Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "$Label-timeout-status.json")
  }
  throw "$Label did not authenticate its expected public FIPS seed within $TimeoutSeconds seconds"
}

function Start-IsolatedRuntime {
  param([string]$Config, [string]$Interface)
  & $Nvpn start --daemon --connect --iface $Interface --config $Config
  if ($LASTEXITCODE -ne 0) {
    throw "failed to start Windows nvpn runtime for $Config"
  }
}

function Wait-DurableRosterAck {
  while ([DateTimeOffset]::UtcNow -lt $RuntimeDeadline) {
    $Verified = $false
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
      & $Fixture verify-runtime `
        --admin-data-dir $AdminDataDir `
        --joiner-data-dir $JoinerDataDir `
        --result $Result *> $null
      $Verified = $LASTEXITCODE -eq 0
    } finally {
      $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($Verified) {
      return
    }
    Start-Sleep -Milliseconds 100
  }
  & $Fixture verify-runtime `
    --admin-data-dir $AdminDataDir `
    --joiner-data-dir $JoinerDataDir `
    --result $Result
  throw "Windows signed roster was not durably applied and acknowledged within $TimeoutSeconds seconds"
}

function Save-Status {
  param([string]$Config, [string]$Name)
  $Status = Read-DaemonStatus $Config
  if (!$Status) {
    throw "could not read final Windows daemon status for $Name"
  }
  $Status | ConvertTo-Json -Depth 20 |
    Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "$Name-status.json")
}

$Metadata = Get-Content -Raw $Result | ConvertFrom-Json
$DefaultRouteBefore = Get-DefaultRouteSnapshot
$DnsBefore = Get-DnsSnapshot
$DefaultRouteBefore |
  Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "default-route-before.json")
$DnsBefore |
  Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "dns-before.json")

try {
  Stop-IsolatedRuntime
  Assert-DirectInternet

  $RuntimeStartedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $RuntimeDeadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  Start-IsolatedRuntime $JoinerConfig "nvpn-mj-joiner"

  $DeliveryStartedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Start-IsolatedRuntime $AdminConfig "nvpn-mj-admin"
  # Authenticate both sides to their different public seeds concurrently. The
  # durable admin outbox safely retains its event until the joiner route exists.
  Wait-PublicSeed `
    $JoinerConfig `
    $Metadata.joinerSeedNpub `
    $Metadata.joinerSeedUrl `
    "joiner"
  Wait-PublicSeed `
    $AdminConfig `
    $Metadata.adminSeedNpub `
    $Metadata.adminSeedUrl `
    "admin"
  Wait-DurableRosterAck
  $DeliveryFinishedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $RuntimeElapsedMs = $DeliveryFinishedMs - $RuntimeStartedMs
  $RuntimeCeilingMs = $TimeoutSeconds * 1000
  if ($RuntimeElapsedMs -gt $RuntimeCeilingMs) {
    throw "Windows real manual join took ${RuntimeElapsedMs}ms; ceiling is ${RuntimeCeilingMs}ms"
  }

  Save-Status $AdminConfig "admin"
  Save-Status $JoinerConfig "joiner"
  $AdminLog = Join-Path $AdminDataDir "daemon.log"
  if (
    !(Test-Path $AdminLog) -or
    !(Select-String `
      -Path $AdminLog `
      -SimpleMatch `
      "delivered and applied one signed join roster over FIPS-TCP to $($Metadata.joinerHex)" `
      -Quiet)
  ) {
    throw "Windows admin daemon log lacks the real durable FIPS-TCP delivery receipt"
  }

  $DefaultRouteActive = Get-DefaultRouteSnapshot
  $DnsActive = Get-DnsSnapshot
  $DefaultRouteActive |
    Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "default-route-active.json")
  $DnsActive |
    Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "dns-active.json")
  if ($DefaultRouteActive -ne $DefaultRouteBefore) {
    throw "Windows manual join changed the device default route in Direct mode"
  }
  if ($DnsActive -ne $DnsBefore) {
    throw "Windows manual join changed device DNS in Direct mode"
  }
  Assert-DirectInternet
} finally {
  Stop-IsolatedRuntime
}

$DefaultRouteAfter = Get-DefaultRouteSnapshot
$DnsAfter = Get-DnsSnapshot
$DefaultRouteAfter |
  Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "default-route-after.json")
$DnsAfter |
  Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "dns-after.json")
if ($DefaultRouteAfter -ne $DefaultRouteBefore) {
  throw "Windows manual-join cleanup did not restore the original default route"
}
if ($DnsAfter -ne $DnsBefore) {
  throw "Windows manual-join cleanup did not restore the original DNS settings"
}
Assert-DirectInternet

$Remaining = @(
  Get-CimInstance Win32_Process -Filter "Name = 'nvpn.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and (
        $_.CommandLine.Contains($AdminConfig) -or
        $_.CommandLine.Contains($JoinerConfig)
      )
    }
)
if ($Remaining.Count -ne 0) {
  throw "Windows manual-join cleanup left an isolated nvpn daemon running"
}
foreach ($Name in @("nvpn-mj-admin", "nvpn-mj-joiner")) {
  $Adapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
  if ($Adapter) {
    throw "Windows manual-join cleanup left tunnel adapter $Name behind"
  }
}

Copy-Item -Force (Join-Path $AdminDataDir "daemon.log") `
  (Join-Path $ArtifactRoot "admin-daemon.log")
Copy-Item -Force (Join-Path $JoinerDataDir "daemon.log") `
  (Join-Path $ArtifactRoot "joiner-daemon.log")
@{
  runtimeStartToDurableAckMs = $DeliveryFinishedMs - $RuntimeStartedMs
  adminStartToDurableAckMs = $DeliveryFinishedMs - $DeliveryStartedMs
  ceilingMs = $TimeoutSeconds * 1000
} | ConvertTo-Json |
  Set-Content -Encoding utf8 (Join-Path $ArtifactRoot "timings.json")

Write-Host "WINDOWS_DESKTOP_MANUAL_JOIN_RUNTIME_E2E_OK"
