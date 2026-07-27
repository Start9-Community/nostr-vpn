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
  [int]$WaitSeconds = 60,
  [int]$SettleSeconds = 3
)

# Real Windows daemon transition check: Direct -> WireGuard -> Direct.
# Run only on a disposable elevated VM. The profile remains external to the
# repository and this script never prints its contents.
$ErrorActionPreference = "Stop"

function Invoke-Nvpn {
  param([string[]]$Arguments)
  & $Binary @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "nvpn $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-BestInternetRoute {
  $route = Find-NetRoute -RemoteIPAddress "1.1.1.1" -ErrorAction Stop |
    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
    Select-Object -First 1
  if (!$route) {
    throw "Windows has no best IPv4 Internet route"
  }
  $route
}

function Test-ExternalHttps {
  # Windows' built-in curl uses Schannel. Its strict certificate-revocation
  # fetch can stall behind a privacy VPN even when TCP, DNS, and verified TLS
  # are healthy. Best-effort still verifies the certificate and fails real
  # routing/TLS errors without turning an unreachable CRL into a false outage.
  & curl.exe -4 --ssl-revoke-best-effort --fail --silent `
    --max-time 12 --output NUL $ProbeUrl
  $LASTEXITCODE -eq 0
}

function Test-ExternalDns {
  try {
    $hostName = ([Uri]$ProbeUrl).DnsSafeHost
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $addresses = [Net.Dns]::GetHostAddresses($hostName) |
      Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork }
    @($addresses).Count -gt 0
  }
  catch {
    $false
  }
}

function Get-PublicIpv4 {
  $value = [string](& curl.exe -4 --fail --silent --show-error `
    --max-time 12 $SourceIpUrl)
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  $parsed = $null
  if (
    ![Net.IPAddress]::TryParse($value.Trim(), [ref]$parsed) -or
    $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork
  ) {
    return $null
  }
  $parsed.ToString()
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

function Get-NvpnExitDnsRules {
  @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object {
      $_.DisplayName -eq "nostr-vpn secure DNS" -or
      $_.Comment -eq "nostr-vpn authenticated DNS-over-HTTPS stub"
    })
}

function Get-NativeWireGuardArtifacts {
  $root = Join-Path $env:ProgramData "nostr-vpn\wireguard"
  if (!(Test-Path -LiteralPath $root -PathType Container)) {
    return @()
  }
  @(
    Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop |
      ForEach-Object { $_.FullName }
  )
}

function Get-EndpointBypassRoutes {
  if ([string]::IsNullOrWhiteSpace($WireGuardEndpointHost)) {
    return @()
  }
  $address = $null
  if (![Net.IPAddress]::TryParse($WireGuardEndpointHost, [ref]$address)) {
    throw "WireGuard fixture endpoint must be a literal IP address"
  }
  $family = if (
    $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
  ) {
    "IPv4"
  } else {
    "IPv6"
  }
  $prefix = if ($family -eq "IPv4") {
    "$($address.ToString())/32"
  } else {
    "$($address.ToString())/128"
  }
  @(
    Get-NetRoute -AddressFamily $family -DestinationPrefix $prefix `
      -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
      ForEach-Object {
        "{0}|{1}|{2}|{3}" -f `
          $_.DestinationPrefix,
          $_.InterfaceIndex,
          $_.NextHop,
          $_.RouteMetric
      }
  )
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

$directRoute = Get-BestInternetRoute
$directInterfaceIndex = [uint32]$directRoute.InterfaceIndex
$directInterfaceAlias = [string]$directRoute.InterfaceAlias
$directNextHop = [string]$directRoute.NextHop
if (!(Test-ExternalDns) -or !(Test-ExternalHttps)) {
  throw "external DNS or HTTPS does not work before the test on Direct"
}
$directSourceIp = Get-PublicIpv4
if ([string]::IsNullOrWhiteSpace($directSourceIp)) {
  throw "Direct did not return a valid public IPv4 source"
}
if ((Get-NvpnExitDnsRules).Count -ne 0) {
  throw "nostr-vpn exit DNS policy already exists before the WireGuard test"
}
$wireGuardServiceName = "WireGuardTunnel`$$WireGuardInterface"
if (
  Get-Service -Name $wireGuardServiceName -ErrorAction SilentlyContinue
) {
  throw "candidate WireGuard service already exists before the test"
}
if (
  Get-NetAdapter -Name $WireGuardInterface -IncludeHidden `
    -ErrorAction SilentlyContinue
) {
  throw "candidate WireGuard adapter already exists before the test"
}
$baselineNativeArtifacts = @(Get-NativeWireGuardArtifacts)
$baselineEndpointRoutes = @(Get-EndpointBypassRoutes)

$wireGuardInterfaceIndex = $null
try {
  $wireGuardTimer = [Diagnostics.Stopwatch]::StartNew()
  Invoke-Nvpn @(
    "set", "--config", $Config,
    "--wireguard-exit-config-file", $WireGuardConfig,
    "--wireguard-exit-enabled", "true"
  )
  Wait-ForCondition "WireGuard to own the best route with external DNS and HTTPS working" {
    $route = Get-BestInternetRoute
    $sourceIp = Get-PublicIpv4
    $sourceMatches = if (
      [string]::IsNullOrWhiteSpace($ExpectedExitSourceIp)
    ) {
      ![string]::IsNullOrWhiteSpace($sourceIp) -and
        $sourceIp -ne $directSourceIp
    } else {
      $sourceIp -eq $ExpectedExitSourceIp
    }
    $route.InterfaceIndex -ne $directInterfaceIndex -and
      (Test-ExternalDns) -and
      (Test-ExternalHttps) -and
      (Test-WireGuardDns) -and
      $sourceMatches
  }
  $wireGuardRoute = Get-BestInternetRoute
  $wireGuardInterfaceIndex = [uint32]$wireGuardRoute.InterfaceIndex

  # Catch delayed route reconciliation that used to invalidate a live tunnel.
  Start-Sleep -Seconds $SettleSeconds
  $settledRoute = Get-BestInternetRoute
  if (
    $settledRoute.InterfaceIndex -ne $wireGuardInterfaceIndex -or
    !(Test-ExternalDns) -or
    !(Test-ExternalHttps) -or
    !(Test-WireGuardDns)
  ) {
    throw "WireGuard route, source, DNS, or HTTPS failed after the settle interval"
  }
  $wireGuardSourceIp = Get-PublicIpv4
  if (
    (![string]::IsNullOrWhiteSpace($ExpectedExitSourceIp) -and
      $wireGuardSourceIp -ne $ExpectedExitSourceIp) -or
    ([string]::IsNullOrWhiteSpace($ExpectedExitSourceIp) -and
      $wireGuardSourceIp -eq $directSourceIp)
  ) {
    throw "public Internet did not use the real WireGuard exit source"
  }
  if ((Get-NvpnExitDnsRules).Count -eq 0) {
    throw "nostr-vpn exit DNS policy was not installed during WireGuard"
  }
  $wireGuardElapsed = [Math]::Round($wireGuardTimer.Elapsed.TotalSeconds, 2)

  $directTimer = [Diagnostics.Stopwatch]::StartNew()
  # Windows PowerShell 5 drops empty native arguments, so use clap's
  # --option=value form to express Direct reliably.
  Invoke-Nvpn @("set", "--config", $Config, "--exit-node=")
  Wait-ForCondition "the original Direct route with external DNS and HTTPS" {
    $route = Get-BestInternetRoute
      $route.InterfaceIndex -eq $directInterfaceIndex -and
      $route.NextHop -eq $directNextHop -and
      (Test-ExternalDns) -and
      (Test-ExternalHttps) -and
      (Get-PublicIpv4) -eq $directSourceIp
  }
  if ($wireGuardInterfaceIndex) {
    $staleDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
      -ErrorAction SilentlyContinue |
      Where-Object { $_.InterfaceIndex -eq $wireGuardInterfaceIndex }
    if ($staleDefault) {
      throw "WireGuard default route remains after switching back to Direct"
    }
  }
  Wait-ForCondition "nostr-vpn exit DNS policy cleanup" {
    (Get-NvpnExitDnsRules).Count -eq 0
  }
  Wait-ForCondition "native WireGuard service and adapter cleanup" {
    !(Get-Service -Name $wireGuardServiceName -ErrorAction SilentlyContinue) -and
      !(Get-NetAdapter -Name $WireGuardInterface -IncludeHidden `
        -ErrorAction SilentlyContinue)
  }
  $remainingArtifacts = @(Get-NativeWireGuardArtifacts)
  if (@(Compare-Object $baselineNativeArtifacts $remainingArtifacts).Count -ne 0) {
    throw "native WireGuard config or ownership artifact leaked after Direct"
  }
  $remainingEndpointRoutes = @(Get-EndpointBypassRoutes)
  if (
    @(Compare-Object $baselineEndpointRoutes $remainingEndpointRoutes).Count `
      -ne 0
  ) {
    throw "WireGuard endpoint bypass route leaked after Direct"
  }
  $directElapsed = [Math]::Round($directTimer.Elapsed.TotalSeconds, 2)

  Write-Output "WINDOWS_WG_DIRECT_E2E_OK"
  Write-Output "WireGuard route, source, DNS, and HTTPS stable after ${wireGuardElapsed}s"
  Write-Output "Direct route, source, DNS, and HTTPS restored on $directInterfaceAlias after ${directElapsed}s"
}
finally {
  # Best-effort fail-safe. This changes only the disposable test VM.
  & $Binary set --config $Config --exit-node= 2>$null | Out-Null
}
