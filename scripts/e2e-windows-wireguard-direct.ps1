param(
  [Parameter(Mandatory = $true)]
  [string]$Binary,
  [Parameter(Mandatory = $true)]
  [string]$Config,
  [Parameter(Mandatory = $true)]
  [string]$WireGuardConfig,
  [string]$ProbeUrl = "https://example.com/",
  [string]$SourceIpUrl = "https://api.ipify.org/",
  [string]$ExpectedExitSourceIp = "",
  [string]$DnsProbeName = "",
  [string]$ExpectedDnsProbeIp = "",
  [string]$WireGuardEndpointHost = "",
  [string]$WireGuardInterface = "nvpn-wg-exit",
  [string]$DirectStatePath = "",
  [int]$WaitSeconds = 60,
  [int]$SettleSeconds = 3
)

# Real Windows daemon transition check: Direct -> WireGuard -> Direct.
# Run only on a disposable elevated VM. The profile remains external to the
# repository and this script never prints its contents.
$ErrorActionPreference = "Stop"
$lifecycleLibrary = Join-Path `
  $PSScriptRoot "e2e-windows-wireguard-direct.lib.ps1"
if (!(Test-Path -LiteralPath $lifecycleLibrary -PathType Leaf)) {
  throw "Windows WireGuard lifecycle library is missing"
}
. $lifecycleLibrary

function Invoke-Nvpn {
  param([string[]]$Arguments)
  & $Binary @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "nvpn $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Test-WireGuardDns {
  if ([string]::IsNullOrWhiteSpace($DnsProbeName)) {
    return $true
  }
  try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $answers = @(
      [Net.Dns]::GetHostAddresses($DnsProbeName) |
        Where-Object {
          $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
        } |
        ForEach-Object { $_.ToString() }
    )
    $answers -contains $ExpectedDnsProbeIp
  }
  catch {
    $false
  }
}

function Wait-ForCondition {
  param(
    [string]$Description,
    [scriptblock]$Condition
  )
  $timer = [Diagnostics.Stopwatch]::StartNew()
  while ($timer.Elapsed.TotalSeconds -lt $WaitSeconds) {
    if (& $Condition) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
  throw "timed out after ${WaitSeconds}s waiting for $Description"
}

function Write-WindowsWireGuardFailureEvidence {
  param([System.Management.Automation.ErrorRecord]$Failure)
  $wg = @(
    (Get-Command wg.exe -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty Source -First 1)
    (Join-Path $env:ProgramFiles "WireGuard\wg.exe")
  ) | Where-Object {
    ![string]::IsNullOrWhiteSpace($_) -and
    (Test-Path -LiteralPath $_ -PathType Leaf)
  } | Select-Object -First 1
  @(
    "failure=$($Failure.Exception.Message)"
    "captured_unix_milliseconds=$(
      [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    )"
    "### latest_handshakes"
    if ($wg) { & $wg show all latest-handshakes 2>&1 } else { "wg.exe missing" }
    "### transfer"
    if ($wg) { & $wg show all transfer 2>&1 } else { "wg.exe missing" }
    "### endpoints"
    if ($wg) { & $wg show all endpoints 2>&1 } else { "wg.exe missing" }
    "### services"
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "WireGuardTunnel`$*" } |
      Format-Table Name, State, ProcessId, PathName -AutoSize | Out-String
    "### adapters"
    Get-WindowsWireGuardTunnelAdapters |
      Format-Table Name, InterfaceDescription, ifIndex, Status -AutoSize |
      Out-String
    "### endpoint_routes"
    Get-WindowsWireGuardEndpointRoutes $WireGuardEndpointHost |
      Format-Table DestinationPrefix, InterfaceIndex, InterfaceAlias,
        NextHop, RouteMetric -AutoSize | Out-String
    "### best_internet_route"
    Get-WindowsWireGuardBestInternetRoute | Format-List | Out-String
  )
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (!$isAdmin) {
  throw "Windows WireGuard/Direct e2e requires an elevated Administrator session"
}
foreach ($path in @($Binary, $Config, $WireGuardConfig)) {
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "required file does not exist: $path"
  }
}

$ownsDirectState = [string]::IsNullOrWhiteSpace($DirectStatePath)
if ($ownsDirectState) {
  $DirectStatePath = Join-Path `
    $env:TEMP `
    ("nvpn-wg-direct-{0}-{1}.json" -f $PID, [Guid]::NewGuid().ToString("N"))
  $directBaseline = Save-WindowsWireGuardDirectBaseline `
    $DirectStatePath `
    $WireGuardInterface `
    $WireGuardEndpointHost `
    $ProbeUrl `
    $SourceIpUrl
} else {
  $directBaseline = Read-WindowsWireGuardDirectBaseline `
    $DirectStatePath `
    $WireGuardInterface `
    $WireGuardEndpointHost
  Assert-WindowsWireGuardDirectRestored `
    $directBaseline `
    $WireGuardInterface `
    $WireGuardEndpointHost `
    $ProbeUrl `
    $SourceIpUrl
}
$directInterfaceIndex = [uint32]$directBaseline.direct_interface_index
$directInterfaceAlias = [string]$directBaseline.direct_interface_alias
$directNextHop = [string]$directBaseline.direct_next_hop
$directSourceIp = [string]$directBaseline.direct_source_ip

$wireGuardInterfaceIndex = $null
$directCleanupComplete = $false
try {
  $wireGuardTimer = [Diagnostics.Stopwatch]::StartNew()
  Invoke-Nvpn @(
    "set", "--config", $Config,
    "--wireguard-exit-config-file", $WireGuardConfig,
    "--wireguard-exit-enabled", "true"
  )
  Wait-ForCondition "WireGuard to own the best route with external DNS and HTTPS working" {
    $route = Get-WindowsWireGuardBestInternetRoute
    $sourceIp = Get-WindowsWireGuardPublicIpv4 $SourceIpUrl
    $sourceMatches = if (
      [string]::IsNullOrWhiteSpace($ExpectedExitSourceIp)
    ) {
      ![string]::IsNullOrWhiteSpace($sourceIp) -and
        $sourceIp -ne $directSourceIp
    } else {
      $sourceIp -eq $ExpectedExitSourceIp
    }
    $route.InterfaceIndex -ne $directInterfaceIndex -and
      (Test-WindowsWireGuardExternalDns $ProbeUrl) -and
      (Test-WindowsWireGuardExternalHttps $ProbeUrl) -and
      (Test-WireGuardDns) -and
      $sourceMatches
  }
  $wireGuardRoute = Get-WindowsWireGuardBestInternetRoute
  $wireGuardInterfaceIndex = [uint32]$wireGuardRoute.InterfaceIndex

  # Catch delayed route reconciliation that used to invalidate a live tunnel.
  Start-Sleep -Seconds $SettleSeconds
  $settledRoute = Get-WindowsWireGuardBestInternetRoute
  if (
    $settledRoute.InterfaceIndex -ne $wireGuardInterfaceIndex -or
    !(Test-WindowsWireGuardExternalDns $ProbeUrl) -or
    !(Test-WindowsWireGuardExternalHttps $ProbeUrl) -or
    !(Test-WireGuardDns)
  ) {
    throw "WireGuard route, source, DNS, or HTTPS failed after the settle interval"
  }
  $wireGuardSourceIp = Get-WindowsWireGuardPublicIpv4 $SourceIpUrl
  if (
    (![string]::IsNullOrWhiteSpace($ExpectedExitSourceIp) -and
      $wireGuardSourceIp -ne $ExpectedExitSourceIp) -or
    ([string]::IsNullOrWhiteSpace($ExpectedExitSourceIp) -and
      $wireGuardSourceIp -eq $directSourceIp)
  ) {
    throw "public Internet did not use the real WireGuard exit source"
  }
  if ((Get-WindowsWireGuardExitDnsRules).Count -eq 0) {
    throw "nostr-vpn exit DNS policy was not installed during WireGuard"
  }
  $wireGuardElapsed = [Math]::Round($wireGuardTimer.Elapsed.TotalSeconds, 2)

  $directTimer = [Diagnostics.Stopwatch]::StartNew()
  # Windows PowerShell 5 drops empty native arguments, so use clap's
  # --option=value form to express Direct reliably.
  Invoke-Nvpn @("set", "--config", $Config, "--exit-node=")
  Wait-ForCondition "the original Direct route with external DNS and HTTPS" {
    $route = Get-WindowsWireGuardBestInternetRoute
      $route.InterfaceIndex -eq $directInterfaceIndex -and
      $route.NextHop -eq $directNextHop -and
      (Test-WindowsWireGuardExternalDns $ProbeUrl) -and
      (Test-WindowsWireGuardExternalHttps $ProbeUrl) -and
      (Get-WindowsWireGuardPublicIpv4 $SourceIpUrl) -eq $directSourceIp
  }
  if ($wireGuardInterfaceIndex) {
    $staleDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
      -ErrorAction SilentlyContinue |
      Where-Object { $_.InterfaceIndex -eq $wireGuardInterfaceIndex }
    if ($staleDefault) {
      throw "WireGuard default route remains after switching back to Direct"
    }
  }
  Invoke-WindowsWireGuardDirectCleanup `
    $Binary `
    $Config `
    $DirectStatePath `
    $WireGuardInterface `
    $WireGuardEndpointHost `
    $ProbeUrl `
    $SourceIpUrl `
    $WaitSeconds | Out-Null
  $directCleanupComplete = $true
  $directElapsed = [Math]::Round($directTimer.Elapsed.TotalSeconds, 2)

  Write-Output "WINDOWS_WG_DIRECT_E2E_OK"
  Write-Output "WireGuard route, source, DNS, and HTTPS stable after ${wireGuardElapsed}s"
  Write-Output "Direct route, source, DNS, and HTTPS restored on $directInterfaceAlias after ${directElapsed}s"
}
catch {
  $runFailure = $_
  try {
    Write-WindowsWireGuardFailureEvidence $runFailure
  }
  catch {
    Write-Warning "could not preserve Windows WireGuard failure evidence: $($_.Exception.Message)"
  }
  throw $runFailure
}
finally {
  if (!$directCleanupComplete) {
    Invoke-WindowsWireGuardDirectCleanup `
      $Binary `
      $Config `
      $DirectStatePath `
      $WireGuardInterface `
      $WireGuardEndpointHost `
      $ProbeUrl `
      $SourceIpUrl `
      $WaitSeconds `
      -AllowOwnedRepair | Out-Null
    $directCleanupComplete = $true
  }
  if ($ownsDirectState -and $directCleanupComplete) {
    Remove-Item -Force -LiteralPath $DirectStatePath `
      -ErrorAction SilentlyContinue
  }
}
