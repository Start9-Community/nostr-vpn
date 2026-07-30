# Canonical native-WireGuard cleanup shared by the Windows guest gate and its
# outer SSH fail-safe. Emergency deletion is allowed only after a clean
# preflight snapshot makes every fixed test resource lane-owned.

function Get-WindowsWireGuardBestInternetRoute {
  $route = Find-NetRoute -RemoteIPAddress "1.1.1.1" -ErrorAction Stop |
    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
    Select-Object -First 1
  if (!$route) { throw "Windows has no best IPv4 Internet route" }
  $route
}

function Test-WindowsWireGuardExternalHttps {
  param([string]$ProbeUrl)
  & curl.exe -4 --ssl-revoke-best-effort --fail --silent `
    --max-time 12 --output NUL $ProbeUrl
  $LASTEXITCODE -eq 0
}

function Test-WindowsWireGuardExternalDns {
  param([string]$ProbeUrl)
  try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $addresses = [Net.Dns]::GetHostAddresses(([Uri]$ProbeUrl).DnsSafeHost) |
      Where-Object {
        $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
      }
    @($addresses).Count -gt 0
  } catch { $false }
}

function Get-WindowsWireGuardPublicIpv4 {
  param([string]$SourceIpUrl)
  $value = [string](& curl.exe -4 --fail --silent --show-error `
    --max-time 12 $SourceIpUrl)
  if ($LASTEXITCODE -ne 0) { return $null }
  $parsed = $null
  if (
    ![Net.IPAddress]::TryParse($value.Trim(), [ref]$parsed) -or
    $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork
  ) {
    return $null
  }
  $parsed.ToString()
}

function Get-WindowsWireGuardExitDnsRules {
  @(
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
      Where-Object {
        $_.DisplayName -eq "nostr-vpn secure DNS" -or
        $_.Comment -eq "nostr-vpn authenticated DNS-over-HTTPS stub"
      }
  )
}

function Get-WindowsWireGuardNativeArtifacts {
  $root = Join-Path $env:ProgramData "nostr-vpn\wireguard"
  if (!(Test-Path -LiteralPath $root -PathType Container)) { return @() }
  @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
}

function Get-WindowsWireGuardEndpointRoutes {
  param([string]$EndpointHost)
  if ([string]::IsNullOrWhiteSpace($EndpointHost)) { return @() }
  $address = $null
  if (
    ![Net.IPAddress]::TryParse($EndpointHost, [ref]$address) -or
    $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork
  ) {
    throw "WireGuard fixture endpoint must be a literal IPv4 address"
  }
  @(
    Get-NetRoute -AddressFamily IPv4 `
      -DestinationPrefix "$($address.ToString())/32" `
      -PolicyStore ActiveStore -ErrorAction SilentlyContinue
  )
}

function Test-WindowsWireGuardResourcesRestored {
  param(
    [object]$Baseline,
    [string]$WireGuardInterface,
    [string]$EndpointHost
  )
  $serviceName = "WireGuardTunnel`$$WireGuardInterface"
  if (
    (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -or
    (Get-NetAdapter -Name $WireGuardInterface -IncludeHidden `
      -ErrorAction SilentlyContinue) -or
    (Get-WindowsWireGuardExitDnsRules).Count -ne 0 -or
    @(Get-WindowsWireGuardNativeArtifacts).Count -ne 0 -or
    @(Get-WindowsWireGuardEndpointRoutes $EndpointHost).Count -ne 0
  ) {
    return $false
  }
  $route = Get-WindowsWireGuardBestInternetRoute
  [int]$route.InterfaceIndex -eq [int]$Baseline.direct_interface_index -and
    [string]$route.NextHop -eq [string]$Baseline.direct_next_hop
}

function Assert-WindowsWireGuardDirectRestored {
  param(
    [object]$Baseline,
    [string]$WireGuardInterface,
    [string]$EndpointHost,
    [string]$ProbeUrl,
    [string]$SourceIpUrl
  )
  if (
    !(Test-WindowsWireGuardResourcesRestored `
      $Baseline $WireGuardInterface $EndpointHost)
  ) {
    throw (
      "native WireGuard service, adapter, artifacts, endpoint route, DNS " +
      "policy, or original Direct route was not restored"
    )
  }
  if (
    !(Test-WindowsWireGuardExternalDns $ProbeUrl) -or
    !(Test-WindowsWireGuardExternalHttps $ProbeUrl)
  ) {
    throw "external DNS or HTTPS did not recover on the original Direct route"
  }
  $sourceIp = Get-WindowsWireGuardPublicIpv4 $SourceIpUrl
  if ($sourceIp -ne [string]$Baseline.direct_source_ip) {
    throw (
      "original Direct public source was not restored: expected {0}, got {1}" `
        -f $Baseline.direct_source_ip, $sourceIp
    )
  }
}

function Save-WindowsWireGuardDirectBaseline {
  param(
    [string]$StatePath,
    [string]$WireGuardInterface,
    [string]$EndpointHost,
    [string]$ProbeUrl,
    [string]$SourceIpUrl
  )
  $route = Get-WindowsWireGuardBestInternetRoute
  $sourceIp = Get-WindowsWireGuardPublicIpv4 $SourceIpUrl
  if (
    !(Test-WindowsWireGuardExternalDns $ProbeUrl) -or
    !(Test-WindowsWireGuardExternalHttps $ProbeUrl) -or
    [string]::IsNullOrWhiteSpace($sourceIp)
  ) {
    throw "Direct DNS, HTTPS, or public IPv4 source failed before the test"
  }
  $serviceName = "WireGuardTunnel`$$WireGuardInterface"
  if (
    (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -or
    (Get-NetAdapter -Name $WireGuardInterface -IncludeHidden `
      -ErrorAction SilentlyContinue) -or
    (Get-WindowsWireGuardExitDnsRules).Count -ne 0 -or
    @(Get-WindowsWireGuardNativeArtifacts).Count -ne 0 -or
    @(Get-WindowsWireGuardEndpointRoutes $EndpointHost).Count -ne 0
  ) {
    throw (
      "Windows WireGuard lane requires no pre-existing native service, " +
      "adapter, artifact, endpoint bypass route, or exit DNS policy"
    )
  }
  $baseline = [PSCustomObject]@{
    schema = 1
    wireguard_interface = $WireGuardInterface
    endpoint_host = $EndpointHost
    direct_interface_index = [int]$route.InterfaceIndex
    direct_interface_alias = [string]$route.InterfaceAlias
    direct_next_hop = [string]$route.NextHop
    direct_source_ip = $sourceIp
    clean_native_resources = $true
  }
  $baseline | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $StatePath -Encoding ASCII
  $baseline
}

function Read-WindowsWireGuardDirectBaseline {
  param(
    [string]$StatePath,
    [string]$WireGuardInterface,
    [string]$EndpointHost
  )
  if (!(Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Windows WireGuard Direct baseline is missing: $StatePath"
  }
  $baseline = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
  if (
    [int]$baseline.schema -ne 1 -or
    [string]$baseline.wireguard_interface -ne $WireGuardInterface -or
    [string]$baseline.endpoint_host -ne $EndpointHost -or
    [string]::IsNullOrWhiteSpace([string]$baseline.direct_source_ip) -or
    $baseline.clean_native_resources -ne $true
  ) {
    throw "Windows WireGuard Direct baseline is invalid or belongs to another lane"
  }
  $baseline
}

function Repair-WindowsWireGuardOwnedResources {
  param([string]$WireGuardInterface, [string]$EndpointHost)
  $serviceName = "WireGuardTunnel`$$WireGuardInterface"
  if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName 2>$null | Out-Null
  }
  $deadline = (Get-Date).AddSeconds(10)
  do {
    if (
      !(Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -and
      !(Get-NetAdapter -Name $WireGuardInterface -IncludeHidden `
        -ErrorAction SilentlyContinue)
    ) { break }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)

  Get-WindowsWireGuardEndpointRoutes $EndpointHost |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  Get-WindowsWireGuardExitDnsRules | ForEach-Object {
    Remove-DnsClientNrptRule -Name $_.Name -Force `
      -ErrorAction SilentlyContinue
  }

  $root = Join-Path $env:ProgramData "nostr-vpn\wireguard"
  if (!(Test-Path -LiteralPath $root)) { return }
  $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
  $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force)
  if (
    !$rootItem.PSIsContainer -or
    ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    @($items | Where-Object {
      ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    }).Count -ne 0
  ) {
    throw "refusing to clean native WireGuard artifacts through a reparse point"
  }
  Get-ChildItem -LiteralPath $root -Force |
    Remove-Item -Recurse -Force -ErrorAction Stop
}

function Invoke-WindowsWireGuardDirectCleanup {
  param(
    [string]$Binary,
    [string]$Config,
    [string]$StatePath,
    [string]$WireGuardInterface,
    [string]$EndpointHost,
    [string]$ProbeUrl,
    [string]$SourceIpUrl,
    [int]$WaitSeconds = 20,
    [switch]$AllowOwnedRepair
  )
  $baseline = Read-WindowsWireGuardDirectBaseline `
    $StatePath $WireGuardInterface $EndpointHost
  try {
    & $Binary set --config $Config --exit-node= 2>$null | Out-Null
    $normalCleanupFailed = $LASTEXITCODE -ne 0
  } catch {
    $normalCleanupFailed = $true
  }

  if (!$normalCleanupFailed) {
    $deadline = (Get-Date).AddSeconds([Math]::Min($WaitSeconds, 10))
    while (
      !(Test-WindowsWireGuardResourcesRestored `
        $baseline $WireGuardInterface $EndpointHost) -and
      (Get-Date) -lt $deadline
    ) {
      Start-Sleep -Milliseconds 250
    }
  }
  if (
    $normalCleanupFailed -or
    !(Test-WindowsWireGuardResourcesRestored `
      $baseline $WireGuardInterface $EndpointHost)
  ) {
    if (!$AllowOwnedRepair) {
      throw "normal Direct cleanup did not restore native WireGuard resources"
    }
    Repair-WindowsWireGuardOwnedResources `
      $WireGuardInterface $EndpointHost
  }

  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  do {
    try {
      Assert-WindowsWireGuardDirectRestored `
        $baseline `
        $WireGuardInterface `
        $EndpointHost `
        $ProbeUrl `
        $SourceIpUrl
      return $baseline
    } catch {
      $lastError = $_
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  throw $lastError
}
