param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Initialize", "Run", "Probe", "WireGuardProbe", "Watchdog", "Cleanup")]
  [string]$Action,
  [Parameter(Mandatory = $true)]
  [string]$Binary,
  [Parameter(Mandatory = $true)]
  [string]$Config,
  [Parameter(Mandatory = $true)]
  [string]$StateDir,
  [string]$PrimaryMac,
  [string]$SecondaryMac,
  [string]$SecondaryAddress,
  [string]$SecondaryGateway,
  [int]$SecondaryPrefixLength = 24,
  [string]$NetworkId,
  [string]$PeerNpub,
  [string]$PeerEndpoint,
  [string]$PeerTunnelIp,
  [string]$WireGuardPeerPublicKey,
  [string]$WireGuardEndpoint,
  [string]$WireGuardClientAddress = "10.232.0.2/32",
  [string]$WireGuardInterface = "nvpn-wg-exit",
  [string]$FixtureDnsName = "underlay-gate.nvpn.test",
  [string]$ProbeUrl = "https://example.com/",
  [string]$ExpectedFipsRevision,
  [string]$TunnelInterface = "nvpn-underlay-gate",
  [int]$ListenPort = 45821,
  [int]$RecoveryDeadlineMilliseconds = 4000,
  [int]$RunnerPid = 0,
  [int]$WatchdogTimeoutSeconds = 300
)

# Production-path Windows underlay handoff gate. The host-side orchestrator
# gives this disposable VM a second physical NIC and cuts/restores the original
# virtual link. This script drives the shipped nvpn daemon, Wintun, route
# reconciliation, secure DNS, and continuous tunnel payload without a mock.
$ErrorActionPreference = "Stop"
$WireGuardPrivateKeyPath = Join-Path $StateDir "wireguard-client-private.key"
$WireGuardConfigPath = Join-Path $StateDir "wireguard-client.conf"
$CleanupJournalPath = Join-Path $StateDir "daemon.cleanup.json"

. (Join-Path $PSScriptRoot "desktop-windows-underlay-change-e2e.lib.ps1")
. (Join-Path $PSScriptRoot "desktop-windows-underlay-crash-recovery.lib.ps1")
function Protect-SecretFile {
  param([string]$Path)
  & icacls.exe $Path /inheritance:r `
    /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "could not restrict ACL on $Path"
  }
}

function New-WireGuardClientKey {
  $wg = Resolve-WireGuardTool "wg.exe"
  $privateKey = ([string](& $wg genkey)).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($privateKey)) {
    throw "wg.exe genkey did not return a private key"
  }
  [IO.File]::WriteAllText(
    $WireGuardPrivateKeyPath,
    $privateKey + [Environment]::NewLine,
    [Text.Encoding]::ASCII
  )
  Protect-SecretFile $WireGuardPrivateKeyPath

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $wg
  $startInfo.Arguments = "pubkey"
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (!$process.Start()) {
    throw "could not start wg.exe pubkey"
  }
  $process.StandardInput.WriteLine($privateKey)
  $process.StandardInput.Close()
  $publicKey = $process.StandardOutput.ReadToEnd().Trim()
  $stderr = $process.StandardError.ReadToEnd().Trim()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($publicKey)) {
    throw "wg.exe pubkey failed: $stderr"
  }
  return $publicKey
}

function Write-WireGuardConfig {
  if (!(Test-Path -LiteralPath $WireGuardPrivateKeyPath -PathType Leaf)) {
    throw "WireGuard client private key is missing"
  }
  $privateKey = (Get-Content -Raw -LiteralPath $WireGuardPrivateKeyPath).Trim()
  $text = @"
[Interface]
PrivateKey = $privateKey
Address = $WireGuardClientAddress
DNS = 1.1.1.1

[Peer]
PublicKey = $WireGuardPeerPublicKey
AllowedIPs = 0.0.0.0/0
Endpoint = $WireGuardEndpoint
PersistentKeepalive = 1
"@
  [IO.File]::WriteAllText(
    $WireGuardConfigPath,
    $text,
    [Text.Encoding]::ASCII
  )
  Protect-SecretFile $WireGuardConfigPath
}

function Test-PhysicalUnderlay {
  param([int]$InterfaceIndex)
  try {
    $adapter = Get-AdapterByIndex $InterfaceIndex
    $address = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex `
      -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object {
        $_.AddressState -eq "Preferred" -and
        !$_.IPAddress.StartsWith("169.254.")
      })
    $defaultRoute = @(Get-NetRoute -InterfaceIndex $InterfaceIndex `
      -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
      -ErrorAction Stop)
    return (
      $adapter.Status -eq "Up" -and
      $address.Count -gt 0 -and
      $defaultRoute.Count -gt 0
    )
  }
  catch {
    return $false
  }
}

function Test-ExternalHttps {
  & curl.exe -4 --ssl-revoke-best-effort --fail --silent `
    --max-time 8 --output NUL $ProbeUrl
  return $LASTEXITCODE -eq 0
}

function Resolve-FixtureDns {
  try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $addresses = [Net.Dns]::GetHostAddresses($FixtureDnsName) |
      Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
      ForEach-Object { $_.ToString() }
    return @($addresses)
  }
  catch {
    return @()
  }
}

function Test-FixtureDns {
  return @((Resolve-FixtureDns) | Where-Object { $_ -eq $PeerTunnelIp }).Count -gt 0
}

function Test-PublicDns {
  try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $hostName = ([Uri]$ProbeUrl).DnsSafeHost
    $addresses = [Net.Dns]::GetHostAddresses($hostName) |
      Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork }
    return @($addresses).Count -gt 0
  }
  catch {
    return $false
  }
}

function Test-DnsName {
  param([string]$Name)
  try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $addresses = [Net.Dns]::GetHostAddresses($Name) |
      Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork }
    return @($addresses).Count -gt 0
  }
  catch {
    return $false
  }
}

function Get-SecureDnsRules {
  return @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object {
      $_.DisplayName -eq "nostr-vpn secure DNS" -or
      $_.Comment -eq "nostr-vpn authenticated DNS-over-HTTPS stub"
    })
}

function Get-RebindReceiptCount {
  $log = Join-Path $StateDir "daemon.stderr.log"
  if (!(Test-Path -LiteralPath $log)) {
    return 0
  }
  return @(
    Select-String -Path $log `
      -SimpleMatch "underlay carrier(s) rebound" `
      -ErrorAction SilentlyContinue
  ).Count
}

function Get-ProbeSuccessCount {
  $log = Join-Path $StateDir "payload.log"
  if (!(Test-Path -LiteralPath $log)) {
    return 0
  }
  return @(
    Select-String -Path $log -Pattern "^OK " -ErrorAction SilentlyContinue
  ).Count
}

function Get-WireGuardProbeSuccessCount {
  $log = Join-Path $StateDir "wireguard-payload.log"
  if (!(Test-Path -LiteralPath $log)) {
    return 0
  }
  return @(
    Select-String -Path $log -Pattern "^OK " -ErrorAction SilentlyContinue
  ).Count
}

function Get-EndpointStartCount {
  $log = Join-Path $StateDir "daemon.stderr.log"
  if (!(Test-Path -LiteralPath $log)) {
    return 0
  }
  return @(
    Select-String -Path $log `
      -Pattern "daemon: (FIPS private mesh on|restarted FIPS private mesh on|rebuilt FIPS private mesh on)" `
      -ErrorAction SilentlyContinue
  ).Count
}

function Assert-SessionContinuity {
  param(
    [int]$ExpectedDaemonPid,
    [int]$ExpectedEndpointStartCount,
    [string]$ExpectedNpub,
    [string]$ExpectedTunnelIp
  )
  if ((Get-DaemonPid) -ne $ExpectedDaemonPid) {
    throw "daemon PID changed during the physical handoff"
  }
  if ((Read-Npub) -ne $ExpectedNpub) {
    throw "local identity changed during the physical handoff"
  }
  $currentTunnelIp = (& $Binary ip --config $Config).Trim()
  if ($LASTEXITCODE -ne 0 -or $currentTunnelIp -ne $ExpectedTunnelIp) {
    throw "tunnel IP changed during the physical handoff"
  }
  if ((Get-EndpointStartCount) -ne $ExpectedEndpointStartCount) {
    throw "FIPS endpoint restarted during the physical handoff"
  }
  $log = Join-Path $StateDir "daemon.stderr.log"
  if (
    (Test-Path -LiteralPath $log) -and
    (Select-String -Path $log `
      -Pattern "daemon: (restarted|rebuilt) FIPS private mesh on" `
      -Quiet -ErrorAction SilentlyContinue)
  ) {
    throw "FIPS endpoint was replaced during the physical handoff"
  }
  if (
    (Test-Path -LiteralPath $log) -and
    (Select-String -Path $log `
      -Pattern "EADDRNOTAVAIL|address not available|cannot assign requested address" `
      -Quiet -ErrorAction SilentlyContinue)
  ) {
    throw "FIPS reported an address-bind failure during the physical handoff"
  }
  Assert-ExpectedFipsRoster (Read-Status)
}

function Assert-ExpectedFipsRoster {
  param($Status)
  $configuredPeers = @($Status.daemon.state.fips_endpoint_peers)
  if (
    $configuredPeers.Count -ne 1 -or
    [string]$configuredPeers[0].npub -ne $PeerNpub
  ) {
    throw "live FIPS endpoint roster drifted from the one expected participant"
  }
}

function Wait-ForCondition {
  param(
    [string]$Description,
    [int]$TimeoutMilliseconds,
    [scriptblock]$Condition,
    [int]$PollMilliseconds = 50
  )
  $timer = [Diagnostics.Stopwatch]::StartNew()
  while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
    if (& $Condition) {
      return $timer.ElapsedMilliseconds
    }
    Start-Sleep -Milliseconds $PollMilliseconds
  }
  throw "timed out after ${TimeoutMilliseconds}ms waiting for $Description"
}

function Wait-ForFile {
  param([string]$Name)
  $path = Join-Path $StateDir $Name
  Wait-ForCondition "host signal $Name" 30000 { Test-Path -LiteralPath $path } 100 |
    Out-Null
}

function Write-Marker {
  param([string]$Name, [string]$Value = "ok")
  [IO.File]::WriteAllText(
    (Join-Path $StateDir $Name),
    $Value,
    [Text.UTF8Encoding]::new($false)
  )
}

function Assert-ActiveExit {
  param(
    [int]$ExpectedPhysicalIndex,
    [int]$ExpectedDaemonPid,
    [bool]$RequireFixtureDns = $true
  )
  $status = Read-Status
  if (
    $status.status_source -ne "daemon" -or
    !$status.daemon.running -or
    [int]$status.daemon.pid -ne $ExpectedDaemonPid -or
    !$status.daemon.state.mesh_ready -or
    [int]$status.daemon.state.connected_peer_count -lt 1 -or
    !([string]$status.daemon.state.fips_core_version).EndsWith(
      "(rev $ExpectedFipsRevision)"
    )
  ) {
    throw "nvpn daemon/mesh status is not ready or its PID changed"
  }
  Assert-ExpectedFipsRoster $status

  $internetRoute = Get-BestRoute "1.1.1.1"
  $wireGuard = Get-WireGuardAdapter
  if ([int]$internetRoute.InterfaceIndex -ne [int]$wireGuard.ifIndex) {
    throw "public Internet is not routed through the real WireGuard exit"
  }

  $endpointHost = Get-WireGuardEndpointHost
  $endpointRoute = Get-BestRoute $endpointHost
  if ([int]$endpointRoute.InterfaceIndex -ne $ExpectedPhysicalIndex) {
    throw "WireGuard endpoint bypass did not move to the expected physical underlay"
  }
  Assert-WireGuardEndpointRoute $ExpectedPhysicalIndex | Out-Null
  if (!(Test-WireGuardHandshake)) {
    throw "WireGuard exit has no successful handshake"
  }
  if ((Get-SecureDnsRules).Count -eq 0) {
    throw "nvpn secure DNS policy is missing while the exit is active"
  }
  if ($RequireFixtureDns -and !(Test-FixtureDns)) {
    throw "fixture name did not resolve through the selected exit DNS server"
  }
  if (!(Test-PublicDns) -or !(Test-ExternalHttps)) {
    throw "public DNS or verified HTTPS failed through the selected exit"
  }
}

function Observe-Recovery {
  param(
    [string]$Label,
    [scriptblock]$NewUnderlayAvailable,
    [int]$ExpectedPhysicalIndex,
    [int]$ExpectedDaemonPid,
    [int]$ExpectedEndpointStartCount,
    [string]$ExpectedNpub,
    [string]$ExpectedTunnelIp
  )
  $rebindBefore = Get-RebindReceiptCount
  Wait-ForCondition "$Label physical underlay to become usable" 30000 $NewUnderlayAvailable 25 |
    Out-Null
  $routeUsableUnixMilliseconds = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $routeUsableMonotonicMilliseconds = [Environment]::TickCount64
  $probeBefore = Get-ProbeSuccessCount
  $wireGuardProbeBefore = Get-WireGuardProbeSuccessCount

  $timer = [Diagnostics.Stopwatch]::StartNew()
  Wait-ForCondition "$Label payload/route/FIPS rebind recovery" `
    $RecoveryDeadlineMilliseconds {
      $endpointHost = Get-WireGuardEndpointHost
      $endpointRoute = Get-BestRoute $endpointHost
      $status = Read-Status
      return (
        [int]$endpointRoute.InterfaceIndex -eq $ExpectedPhysicalIndex -and
        (Get-ProbeSuccessCount) -gt $probeBefore -and
        (Get-WireGuardProbeSuccessCount) -gt $wireGuardProbeBefore -and
        (Get-RebindReceiptCount) -eq ($rebindBefore + 1) -and
        $status.daemon.running -and
        [int]$status.daemon.pid -eq $ExpectedDaemonPid -and
        $status.daemon.state.mesh_ready
      )
  } 25 | Out-Null

  Assert-ActiveExit $ExpectedPhysicalIndex $ExpectedDaemonPid
  Assert-SessionContinuity `
    $ExpectedDaemonPid `
    $ExpectedEndpointStartCount `
    $ExpectedNpub `
    $ExpectedTunnelIp
  $rebindAfter = Get-RebindReceiptCount
  if ($rebindAfter -ne ($rebindBefore + 1)) {
    throw "$Label did not produce exactly one FIPS carrier rebind"
  }
  $wireGuardEndpointRoute = Assert-WireGuardEndpointRoute $ExpectedPhysicalIndex
  $elapsed = [int]$timer.ElapsedMilliseconds
  if ($elapsed -gt $RecoveryDeadlineMilliseconds) {
    throw "$Label stable recovery exceeded ${RecoveryDeadlineMilliseconds}ms ($elapsed ms)"
  }
  $recoveredMonotonicMilliseconds = [Environment]::TickCount64
  Write-Marker "$Label.receipt.json" (
    [PSCustomObject]@{
      recovery_milliseconds = $elapsed
      route_usable_unix_milliseconds = $routeUsableUnixMilliseconds
      route_usable_monotonic_milliseconds = $routeUsableMonotonicMilliseconds
      recovered_monotonic_milliseconds = $recoveredMonotonicMilliseconds
      daemon_pid = $ExpectedDaemonPid
      physical_interface_index = $ExpectedPhysicalIndex
      identity_npub = $ExpectedNpub
      tunnel_ip = $ExpectedTunnelIp
      participant_npub = $PeerNpub
      endpoint_start_count = $ExpectedEndpointStartCount
      payload_successes_before = $probeBefore
      payload_successes_after = Get-ProbeSuccessCount
      wireguard_payload_successes_before = $wireGuardProbeBefore
      wireguard_payload_successes_after = Get-WireGuardProbeSuccessCount
      wireguard_endpoint_route = $wireGuardEndpointRoute
      rebind_receipts_before = $rebindBefore
      rebind_receipts_after = $rebindAfter
    } | ConvertTo-Json -Compress
  )
}

function Run-DnsSettingCase {
  param(
    [string]$Name,
    [string[]]$SetArguments,
    [string]$LookupName,
    [int]$ExpectedDaemonPid,
    [int]$ExpectedPhysicalIndex
  )
  Wait-ForFile "dns-$Name.go"
  Invoke-Nvpn (@("set", "--config", $Config) + $SetArguments)
  Wait-ForCondition "real $Name DNS lookup through the active exit" 30000 {
    try {
      $lookupOk = if ($LookupName -eq $FixtureDnsName) {
        Test-FixtureDns
      }
      else {
        Test-DnsName $LookupName
      }
      Assert-ActiveExit $ExpectedPhysicalIndex $ExpectedDaemonPid $false
      return $lookupOk
    }
    catch {
      return $false
    }
  } 250 | Out-Null
  Write-Marker "dns-$Name.receipt" $LookupName
}

function Restore-AdapterConfiguration {
  $statePath = Join-Path $StateDir "adapter-state.json"
  if (!(Test-Path -LiteralPath $statePath)) {
    return
  }
  $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $primary = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
    Where-Object {
      [int]$_.ifIndex -eq [int]$state.primary_interface_index
    } | Select-Object -First 1)
  if ($primary.Count -eq 1) {
    if ([string]$state.primary_automatic_metric -eq "Enabled") {
      Set-NetIPInterface -InterfaceIndex $primary.ifIndex -AddressFamily IPv4 `
        -AutomaticMetric Enabled -ErrorAction SilentlyContinue
    }
    else {
      Set-NetIPInterface -InterfaceIndex $primary.ifIndex -AddressFamily IPv4 `
        -AutomaticMetric Disabled -InterfaceMetric ([int]$state.primary_metric) `
        -ErrorAction SilentlyContinue
    }
  }
}

function Remove-ExitWireGuardService {
  $serviceName = 'WireGuardTunnel$' + $WireGuardInterface
  $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($service) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName 2>$null | Out-Null
    Wait-ForCondition "WireGuard exit service removal" 5000 {
      !(Get-Service -Name $serviceName -ErrorAction SilentlyContinue)
    } 100 | Out-Null
  }
  Remove-Item -LiteralPath (
    Join-Path $env:ProgramData "nostr-vpn\wireguard\$WireGuardInterface.conf"
  ) -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $WireGuardConfigPath `
    -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $WireGuardPrivateKeyPath `
    -Force -ErrorAction SilentlyContinue
}

function Invoke-IsolatedNetworkCleanup {
  param([switch]$EmergencyRepair)
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  Write-Marker "stop-probe"
  & $Binary stop --config $Config --timeout-secs 5 --force 2>$null | Out-Null
  $stopExitCode = $LASTEXITCODE
  $failures = @()
  if ($stopExitCode -ne 0) {
    $failures += "normal nvpn stop failed with exit code $stopExitCode"
  }
  try {
    Assert-NativeNetworkRestoredBeforeRepair
  }
  catch {
    $failures += $_.Exception.Message
  }
  if ($failures.Count -gt 0 -and $EmergencyRepair) {
    Write-Marker "emergency-repair-invoked" ($failures -join "; ")
    & $Binary repair-network --config $Config 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      $failures += "emergency repair-network failed with exit code $LASTEXITCODE"
    }
  }
  Remove-ExitWireGuardService
  Restore-AdapterConfiguration
  if ($failures.Count -gt 0) {
    throw ($failures -join "; ")
  }
}

Assert-Administrator

switch ($Action) {
  "Initialize" {
    foreach ($value in @(
      $PrimaryMac,
      $SecondaryMac,
      $SecondaryAddress,
      $SecondaryGateway,
      $NetworkId
    )) {
      if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Initialize is missing a required underlay/config argument"
      }
    }
    if (!(Test-Path -LiteralPath $Binary -PathType Leaf)) {
      throw "candidate nvpn binary does not exist"
    }
    if (Get-Process nvpn -ErrorAction SilentlyContinue) {
      throw "another nvpn process is already running before the isolated gate"
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Get-ChildItem -LiteralPath $StateDir -Force -ErrorAction SilentlyContinue |
      Remove-Item -Recurse -Force

    $primary = Get-AdapterByMac $PrimaryMac
    $secondary = Get-AdapterByMac $SecondaryMac
    Enable-NetAdapter -Name $secondary.Name -Confirm:$false
    $primaryIp = Get-NetIPInterface -InterfaceIndex $primary.ifIndex `
      -AddressFamily IPv4 -ErrorAction Stop
    [PSCustomObject]@{
      primary_interface_index = [int]$primary.ifIndex
      secondary_interface_index = [int]$secondary.ifIndex
      primary_metric = [int]$primaryIp.InterfaceMetric
      primary_automatic_metric = [string]$primaryIp.AutomaticMetric
    } | ConvertTo-Json -Compress |
      Set-Content -LiteralPath (Join-Path $StateDir "adapter-state.json") `
        -Encoding ASCII

    Set-NetIPInterface -InterfaceIndex $primary.ifIndex -AddressFamily IPv4 `
      -AutomaticMetric Disabled -InterfaceMetric 10
    Set-NetIPInterface -InterfaceIndex $secondary.ifIndex -AddressFamily IPv4 `
      -Dhcp Disabled -AutomaticMetric Disabled -InterfaceMetric 600
    Get-NetRoute -InterfaceIndex $secondary.ifIndex -AddressFamily IPv4 `
      -ErrorAction SilentlyContinue |
      Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceIndex $secondary.ifIndex -AddressFamily IPv4 `
      -ErrorAction SilentlyContinue |
      Where-Object { $_.PrefixOrigin -ne "WellKnown" } |
      Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $secondary.ifIndex `
      -IPAddress $SecondaryAddress `
      -PrefixLength $SecondaryPrefixLength `
      -DefaultGateway $SecondaryGateway |
      Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $secondary.ifIndex `
      -ServerAddresses @("1.1.1.1")

    Invoke-Nvpn @("init", "--config", $Config, "--force")
    Invoke-Nvpn @("set", "--config", $Config, "--network-id", $NetworkId)
    $npub = Read-Npub
    $tunnelIp = (& $Binary ip --config $Config).Trim()
    if ($LASTEXITCODE -ne 0 -or !$tunnelIp) {
      throw "could not derive the Windows tunnel IP"
    }
    $wireGuardPublicKey = New-WireGuardClientKey
    $primaryAddress = Get-PreferredIPv4Address ([int]$primary.ifIndex)
    $primaryDefault = Get-PhysicalDefaultRoute ([int]$primary.ifIndex)
    [PSCustomObject]@{
      npub = $npub
      tunnel_ip = $tunnelIp
      primary_interface_index = [int]$primary.ifIndex
      secondary_interface_index = [int]$secondary.ifIndex
      primary_address = [string]$primaryAddress.IPAddress
      primary_gateway = [string]$primaryDefault.NextHop
      wireguard_public_key = $wireGuardPublicKey
    } | ConvertTo-Json -Compress
  }

  "Probe" {
    if ([string]::IsNullOrWhiteSpace($PeerTunnelIp)) {
      throw "Probe requires PeerTunnelIp"
    }
    $payload = [Text.Encoding]::ASCII.GetBytes("nvpn-real-underlay-payload")
    $ping = [Net.NetworkInformation.Ping]::new()
    $log = Join-Path $StateDir "payload.log"
    while (!(Test-Path -LiteralPath (Join-Path $StateDir "stop-probe"))) {
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      try {
        $reply = $ping.Send($PeerTunnelIp, 750, $payload)
        if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
          Add-Content -LiteralPath $log -Value "OK $now" -Encoding ASCII
        }
        else {
          Add-Content -LiteralPath $log -Value "FAIL $now $($reply.Status)" -Encoding ASCII
        }
      }
      catch {
        Add-Content -LiteralPath $log -Value "FAIL $now exception" -Encoding ASCII
      }
      Start-Sleep -Milliseconds 100
    }
  }

  "WireGuardProbe" {
    $log = Join-Path $StateDir "wireguard-payload.log"
    while (!(Test-Path -LiteralPath (Join-Path $StateDir "stop-probe"))) {
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      & curl.exe -4 --ssl-revoke-best-effort --fail --silent `
        --max-time 2 --output NUL $ProbeUrl
      if ($LASTEXITCODE -eq 0) {
        Add-Content -LiteralPath $log -Value "OK $now" -Encoding ASCII
      }
      else {
        Add-Content -LiteralPath $log -Value "FAIL $now" -Encoding ASCII
      }
      Start-Sleep -Milliseconds 100
    }
  }

  "Watchdog" {
    if ($RunnerPid -le 0) {
      throw "Watchdog requires RunnerPid"
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WatchdogTimeoutSeconds)
    $complete = Join-Path $StateDir "watchdog.complete"
    while (
      [DateTimeOffset]::UtcNow -lt $deadline -and
      (Get-Process -Id $RunnerPid -ErrorAction SilentlyContinue) -and
      !(Test-Path -LiteralPath $complete)
    ) {
      Start-Sleep -Milliseconds 500
    }
    if (!(Test-Path -LiteralPath $complete)) {
      Invoke-IsolatedNetworkCleanup -EmergencyRepair
      Write-Marker "watchdog-fired"
    }
  }

  "Run" {
    foreach ($value in @(
      $PrimaryMac,
      $SecondaryMac,
      $NetworkId,
      $PeerNpub,
      $PeerEndpoint,
      $PeerTunnelIp,
      $WireGuardPeerPublicKey,
      $WireGuardEndpoint,
      $WireGuardClientAddress,
      $WireGuardInterface,
      $ExpectedFipsRevision
    )) {
      if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Run is missing a required peer/underlay argument"
      }
    }
    $primary = Get-AdapterByMac $PrimaryMac
    $secondary = Get-AdapterByMac $SecondaryMac
    $daemon = $null
    $probe = $null
    $wireGuardProbe = $null
    $watchdog = $null
    try {
      Remove-Item -LiteralPath (Join-Path $StateDir "watchdog.complete") `
        -Force -ErrorAction SilentlyContinue
      $watchdogArgs = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-Action", "Watchdog",
        "-Binary", $Binary,
        "-Config", $Config,
        "-StateDir", $StateDir,
        "-RunnerPid", "$PID",
        "-WatchdogTimeoutSeconds", "$WatchdogTimeoutSeconds"
      )
      $watchdog = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $watchdogArgs -WindowStyle Hidden -PassThru
      Write-Marker "watchdog.pid" "$($watchdog.Id)"

      Write-WireGuardConfig
      Invoke-Nvpn @(
        "set", "--config", $Config,
        "--network-id", $NetworkId,
        "--participant", $PeerNpub,
        "--listen-port", "$ListenPort",
        "--fips-advertise-public-endpoint", "false",
        "--fips-nostr-discovery-enabled", "false",
        "--lan-discovery-enabled", "false",
        "--fips-webrtc-enabled", "false",
        "--fips-bootstrap-enabled", "false",
        "--fips-peer-endpoint", "${PeerNpub}=${PeerEndpoint}",
        "--wireguard-exit-config-file", $WireGuardConfigPath,
        "--wireguard-exit-interface", $WireGuardInterface,
        "--wireguard-exit-enabled", "true",
        "--exit-node-leak-protection", "true",
        "--exit-dns-mode", "through_exit",
        "--exit-dns-through-exit-servers", $PeerTunnelIp,
        "--autoconnect", "true"
      )

      $daemon = Start-CandidateDaemon "daemon"

      Wait-ForCondition "candidate daemon PID file" 30000 {
        try { (Get-DaemonPid) -eq $daemon.Id } catch { $false }
      } 100 | Out-Null
      $daemonPid = Get-DaemonPid
      $identityNpub = Read-Npub
      $tunnelIp = (& $Binary ip --config $Config).Trim()
      if ($LASTEXITCODE -ne 0 -or !$tunnelIp) {
        throw "could not read the running Windows tunnel IP"
      }
      Wait-ForCondition "single FIPS endpoint start receipt" 5000 {
        (Get-EndpointStartCount) -eq 1
      } 50 | Out-Null
      $endpointStartCount = Get-EndpointStartCount

      $probeArgs = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-Action", "Probe",
        "-Binary", $Binary,
        "-Config", $Config,
        "-StateDir", $StateDir,
        "-PeerTunnelIp", $PeerTunnelIp
      )
      $probe = Start-Process -FilePath "powershell.exe" -ArgumentList $probeArgs `
        -WindowStyle Hidden -PassThru

      $wireGuardProbeArgs = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-Action", "WireGuardProbe",
        "-Binary", $Binary,
        "-Config", $Config,
        "-StateDir", $StateDir,
        "-ProbeUrl", $ProbeUrl
      )
      $wireGuardProbe = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $wireGuardProbeArgs -WindowStyle Hidden -PassThru

      Wait-ForCondition "initial FIPS, WireGuard exit, DNS, HTTPS, and payload" 30000 {
        try {
          Assert-ActiveExit ([int]$primary.ifIndex) $daemonPid
          return (
            (Get-ProbeSuccessCount) -gt 2 -and
            (Get-WireGuardProbeSuccessCount) -gt 1
          )
        }
        catch {
          Write-Marker "last-condition-error.txt" $_.Exception.Message
          return $false
        }
      } 250 | Out-Null
      Assert-NativeWireGuardSecretAcl
      Write-Marker "ready" "$daemonPid"

      Wait-ForFile "arm-secondary"
      Write-Marker "armed-secondary"
      Observe-Recovery "secondary" {
        (Get-AdapterByIndex ([int]$primary.ifIndex)).Status -ne "Up" -and
        (Test-PhysicalUnderlay ([int]$secondary.ifIndex))
      } ([int]$secondary.ifIndex) $daemonPid $endpointStartCount $identityNpub $tunnelIp

      Wait-ForFile "arm-primary"
      Write-Marker "armed-primary"
      Observe-Recovery "primary" {
        Test-PhysicalUnderlay ([int]$primary.ifIndex)
      } ([int]$primary.ifIndex) $daemonPid $endpointStartCount $identityNpub $tunnelIp

      Run-DnsSettingCase "automatic" @(
        "--exit-dns-mode", "automatic"
      ) "example.com" $daemonPid ([int]$primary.ifIndex)
      Run-DnsSettingCase "cloudflare" @(
        "--exit-dns-mode", "encrypted",
        "--exit-dns-doh-provider", "cloudflare"
      ) "www.cloudflare.com" $daemonPid ([int]$primary.ifIndex)
      Run-DnsSettingCase "quad9" @(
        "--exit-dns-mode", "encrypted",
        "--exit-dns-doh-provider", "quad9"
      ) "www.quad9.net" $daemonPid ([int]$primary.ifIndex)
      Run-DnsSettingCase "custom" @(
        "--exit-dns-mode", "encrypted",
        "--exit-dns-doh-provider", "custom",
        "--exit-dns-custom-doh-url", "https://dns.google/dns-query",
        "--exit-dns-custom-doh-bootstrap-ips", "8.8.8.8,8.8.4.4"
      ) "iana.org" $daemonPid ([int]$primary.ifIndex)
      Run-DnsSettingCase "through-exit" @(
        "--exit-dns-mode", "through_exit",
        "--exit-dns-through-exit-servers", $PeerTunnelIp
      ) $FixtureDnsName $daemonPid ([int]$primary.ifIndex)

      Wait-ForFile "select-direct"
      $daemon = Invoke-CrashRecovery `
        $daemon `
        ([int]$primary.ifIndex) `
        $identityNpub `
        $tunnelIp
      Write-Marker "done"
    }
    finally {
      Invoke-IsolatedNetworkCleanup -EmergencyRepair
      if ($probe) {
        Wait-Process -Id $probe.Id -Timeout 3 -ErrorAction SilentlyContinue
        Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
      }
      if ($wireGuardProbe) {
        Wait-Process -Id $wireGuardProbe.Id -Timeout 3 -ErrorAction SilentlyContinue
        Stop-Process -Id $wireGuardProbe.Id -Force -ErrorAction SilentlyContinue
      }
      if ($daemon) {
        Wait-Process -Id $daemon.Id -Timeout 5 -ErrorAction SilentlyContinue
        Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
      }
      Write-Marker "watchdog.complete"
      if ($watchdog) {
        Wait-Process -Id $watchdog.Id -Timeout 3 -ErrorAction SilentlyContinue
        Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }

  "Cleanup" {
    Invoke-IsolatedNetworkCleanup -EmergencyRepair
    Write-Marker "watchdog.complete"
    $watchdogPath = Join-Path $StateDir "watchdog.pid"
    if (Test-Path -LiteralPath $watchdogPath) {
      $watchdogPid = [int](Get-Content -Raw -LiteralPath $watchdogPath)
      Stop-Process -Id $watchdogPid -Force -ErrorAction SilentlyContinue
    }
  }
}
