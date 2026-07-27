# Transient elevated Windows adapter for the nvpn fleet canary. The checked-in
# SSH driver prepends $script:FleetPayloadB64 and streams this file to
# powershell.exe -Command -. Nothing from this adapter is installed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:NvpnServiceName = 'NvpnService'

function Fail([string]$Message) {
    throw $Message
}

function ShaBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function ShaText([string]$Text) {
    return ShaBytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function ShaFile([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function CanonicalJson($Value) {
    return ($Value | ConvertTo-Json -Compress -Depth 32)
}

function AtomicJson([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.tmp-' + $PID)
    [IO.File]::WriteAllText(
        $temporary,
        (CanonicalJson $Value) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function RequireAbsolutePath($Value, [string]$Label) {
    if (!($Value -is [string]) -or ![IO.Path]::IsPathFullyQualified($Value)) {
        Fail "$Label must be an absolute Windows path"
    }
    if ($Value -match '(^|[\\/])\.\.([\\/]|$)') {
        Fail "$Label cannot contain parent traversal"
    }
    return [IO.Path]::GetFullPath($Value)
}

function AssertElevated {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Windows fleet install/rollback requires an elevated SSH account'
    }
}

function GetServiceObject([string]$Name) {
    return Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
}

function GetProcessIds {
    return @(
        Get-Process -Name nvpn -ErrorAction SilentlyContinue |
            Sort-Object Id |
            ForEach-Object { [int]$_.Id }
    )
}

function DefinitionValue($Service) {
    if ($null -eq $Service) {
        return $null
    }
    return [ordered]@{
        Name = [string]$Service.Name
        PathName = [string]$Service.PathName
        StartMode = [string]$Service.StartMode
        ServiceType = [string]$Service.ServiceType
    }
}

function ServiceSnapshot([string]$Name, [string]$BinaryPath) {
    $service = GetServiceObject $Name
    $installed = $null -ne $service
    $running = $installed -and $service.State -eq 'Running'
    $enabled = $installed -and $service.StartMode -eq 'Auto'
    $processes = @(GetProcessIds)
    $binaryPresent = Test-Path -LiteralPath $BinaryPath -PathType Leaf
    $definition = DefinitionValue $service
    return [ordered]@{
        installed = [bool]$installed
        enabled = [bool]$enabled
        running = [bool]$running
        binaryPresent = [bool]$binaryPresent
        binarySha256 = $(if ($binaryPresent) { ShaFile $BinaryPath } else { $null })
        definitionSha256 = $(if ($installed) { ShaText (CanonicalJson $definition) } else { $null })
        processCount = [int]$processes.Count
        pid = $(if ($running -and [int]$service.ProcessId -gt 0) { [int]$service.ProcessId } else { $null })
        _definition = $definition
        _processes = $processes
        _pathName = $(if ($installed) { [string]$service.PathName } else { '' })
    }
}

function InvokeNvpnJson([string]$Binary, [string[]]$Arguments) {
    $output = & $Binary @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "nvpn command failed: $($output -join "`n")"
    }
    try {
        return (($output -join "`n") | ConvertFrom-Json)
    } catch {
        Fail "nvpn command did not return JSON: $_"
    }
}

function PeerIdentity($Peer) {
    foreach ($field in @('participant_pubkey', 'public_key', 'node_id')) {
        $value = [string]$Peer.$field
        if (![string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }
    Fail 'nvpn status peer lacks an identity'
}

function ConfigSnapshot([string]$ConfigPath, $Status) {
    if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Fail "nvpn config is missing: $ConfigPath"
    }
    $networkId = [string]$Status.network_id
    $deviceId = [string]$Status.device_id
    if ([string]::IsNullOrWhiteSpace($networkId) -or [string]::IsNullOrWhiteSpace($deviceId)) {
        Fail 'nvpn status lacks network or local-device identity'
    }
    $expectedPeers = [int]$Status.expected_peer_count
    if ($expectedPeers -lt 0) {
        Fail 'nvpn status expected_peer_count is invalid'
    }
    $signedRosters = Join-Path (Split-Path -Parent $ConfigPath) 'signed-rosters.json'
    if (!(Test-Path -LiteralPath $signedRosters -PathType Leaf)) {
        Fail "signed roster store is missing: $signedRosters"
    }
    $roster = @(
        @($Status.peers) |
            ForEach-Object {
                [ordered]@{
                    identity = PeerIdentity $_
                    tunnelIp = [string]$_.tunnel_ip
                }
            } |
            Sort-Object identity, tunnelIp -Unique
    )
    $rosterValue = [ordered]@{
        networkId = $networkId
        localDeviceId = $deviceId
        expectedPeerCount = $expectedPeers
        peers = $roster
    }
    return [ordered]@{
        sha256 = ShaFile $ConfigPath
        signedRosterStoreSha256 = ShaFile $signedRosters
        rosterIdentitySha256 = ShaText (CanonicalJson $rosterValue)
        rosterPeerCount = $expectedPeers
        localDeviceIdentitySha256 = ShaText $deviceId
        networkIdentitySha256 = ShaText $networkId
    }
}

function DirectMode($Status) {
    $wireguard = $Status.wireguard_exit
    $wireguardEnabled = $null -ne $wireguard -and $wireguard.enabled -eq $true
    $exitNode = [string]$Status.exit_node
    return !$wireguardEnabled -and [string]::IsNullOrWhiteSpace($exitNode)
}

function RouteRows {
    return @(
        Get-NetRoute -AddressFamily IPv4,IPv6 |
            Sort-Object AddressFamily, DestinationPrefix, InterfaceIndex, NextHop, RouteMetric |
            Select-Object AddressFamily, DestinationPrefix, InterfaceIndex, InterfaceAlias, NextHop, RouteMetric, Protocol
    )
}

function ResolverRows {
    return @(
        Get-DnsClientServerAddress |
            Sort-Object InterfaceIndex, AddressFamily |
            Select-Object InterfaceIndex, InterfaceAlias, AddressFamily, ServerAddresses
    )
}

function NetworkSnapshot($Status, $Checks) {
    $routes = @(RouteRows)
    $defaults = @($routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') })
    $resolvers = @(ResolverRows)
    $interface = [string]$Status.wireguard_exit.interface
    $ownedRoutes = @(
        $defaults | Where-Object {
            ![string]::IsNullOrWhiteSpace($interface) -and $_.InterfaceAlias -eq $interface
        }
    )
    $ownedResolver = @(
        $resolvers | Where-Object {
            ![string]::IsNullOrWhiteSpace($interface) -and
            $_.InterfaceAlias -eq $interface -and
            @($_.ServerAddresses).Count -gt 0
        }
    )
    $dnsResolved = $false
    try {
        $dnsResolved = @(Resolve-DnsName -Name ([string]$Checks.dnsName) -ErrorAction Stop).Count -gt 0
    } catch {}
    $publicInternet = $false
    try {
        $response = Invoke-WebRequest -Uri ([string]$Checks.directUrl) -UseBasicParsing -TimeoutSec 10
        $publicInternet = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
    } catch {}
    $routeJson = CanonicalJson $routes
    $defaultJson = CanonicalJson $defaults
    $resolverJson = CanonicalJson $resolvers
    $direct = DirectMode $Status
    return [ordered]@{
        directMode = [bool]$direct
        wireguardExitEnabled = [bool](!$direct)
        dnsResolved = [bool]$dnsResolved
        publicInternet = [bool]$publicInternet
        resolverFingerprint = ShaText $resolverJson
        defaultRouteFingerprint = ShaText $defaultJson
        routeTableFingerprint = ShaText $routeJson
        ownedRouteCount = [int]$ownedRoutes.Count
        ownedResolverArtifactCount = [int]$ownedResolver.Count
        _routesJson = $routeJson
        _resolverJson = $resolverJson
    }
}

function MachineIdentity {
    $value = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        Fail 'Windows MachineGuid is unavailable'
    }
    return ShaText ([string]$value).Trim()
}

function PendingTransactions([string]$Root) {
    if (!(Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }
    $pending = @()
    foreach ($journalPath in Get-ChildItem -LiteralPath $Root -Filter journal.json -Recurse -File) {
        try {
            $journal = Get-Content -LiteralPath $journalPath.FullName -Raw | ConvertFrom-Json
            if ($journal.state -in @('preparing', 'installing', 'rolling-back')) {
                $pending += $journalPath.Directory.Name
            }
        } catch {
            $pending += $journalPath.Directory.Name
        }
    }
    return @($pending | Sort-Object -Unique)
}

function PublicService($Value) {
    return [ordered]@{
        installed = [bool]$Value.installed
        enabled = [bool]$Value.enabled
        running = [bool]$Value.running
        binaryPresent = [bool]$Value.binaryPresent
        binarySha256 = $Value.binarySha256
        definitionSha256 = $Value.definitionSha256
        processCount = [int]$Value.processCount
        pid = $Value.pid
    }
}

function PublicNetwork($Value) {
    return [ordered]@{
        directMode = [bool]$Value.directMode
        wireguardExitEnabled = [bool]$Value.wireguardExitEnabled
        dnsResolved = [bool]$Value.dnsResolved
        publicInternet = [bool]$Value.publicInternet
        resolverFingerprint = [string]$Value.resolverFingerprint
        defaultRouteFingerprint = [string]$Value.defaultRouteFingerprint
        routeTableFingerprint = [string]$Value.routeTableFingerprint
        ownedRouteCount = [int]$Value.ownedRouteCount
        ownedResolverArtifactCount = [int]$Value.ownedResolverArtifactCount
    }
}

function ResolveNvpnServiceName($Deployment) {
    $serviceName = if ($Deployment.serviceName) {
        [string]$Deployment.serviceName
    } else {
        $script:NvpnServiceName
    }
    if ($serviceName -ne $script:NvpnServiceName) {
        Fail "Windows fleet serviceName must be $script:NvpnServiceName"
    }
    return $serviceName
}

function Capture($Target, $Checks) {
    $deployment = $Target.deployment
    $serviceName = ResolveNvpnServiceName $deployment
    $binary = RequireAbsolutePath $deployment.binaryPath 'binaryPath'
    $config = RequireAbsolutePath $deployment.configPath 'configPath'
    $probeBinary = RequireAbsolutePath $(if ($deployment.probeBinaryPath) { $deployment.probeBinaryPath } else { $binary }) 'probeBinaryPath'
    if (!(Test-Path -LiteralPath $probeBinary -PathType Leaf)) {
        Fail "probe CLI does not exist: $probeBinary"
    }
    $status = InvokeNvpnJson $probeBinary @('status', '--config', $config, '--json', '--discover-secs', '0')
    return [ordered]@{
        service = ServiceSnapshot $serviceName $binary
        config = ConfigSnapshot $config $status
        network = NetworkSnapshot $status $Checks
        status = $status
        binaryPath = $binary
        configPath = $config
        serviceName = $serviceName
    }
}

function AssertExpected($State, $Target, $Expected) {
    $frozen = $Target.expected
    if ((MachineIdentity) -ne [string]$frozen.machineIdentitySha256) {
        Fail 'remote machine identity changed'
    }
    $pairs = @{
        configSha256 = 'sha256'
        signedRosterStoreSha256 = 'signedRosterStoreSha256'
        rosterIdentitySha256 = 'rosterIdentitySha256'
        rosterPeerCount = 'rosterPeerCount'
        localDeviceIdentitySha256 = 'localDeviceIdentitySha256'
        networkIdentitySha256 = 'networkIdentitySha256'
    }
    foreach ($field in $pairs.Keys) {
        if ($State.config.($pairs[$field]) -ne $frozen.$field) {
            Fail "frozen $field changed before install"
        }
    }
    if (!$State.network.directMode -or [int]$State.network.ownedRouteCount -ne 0 -or [int]$State.network.ownedResolverArtifactCount -ne 0) {
        Fail 'target is not in clean Direct mode'
    }
    if ((CanonicalJson $Expected.expected) -ne (CanonicalJson $frozen)) {
        Fail 'expectations do not bind the frozen target identity'
    }
}

function WriteJournal([string]$Transaction, [string]$TargetId, [string]$TransactionId, [string]$State) {
    $path = Join-Path $Transaction 'journal.json'
    AtomicJson $path ([ordered]@{
        schema = 1
        targetId = $TargetId
        transactionId = $TransactionId
        state = $State
        updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
    return ShaFile $path
}

function SnapshotTransaction([string]$Transaction, $State, $Target) {
    [IO.Directory]::CreateDirectory($Transaction) | Out-Null
    $snapshot = Join-Path $Transaction 'snapshot'
    [IO.Directory]::CreateDirectory($snapshot) | Out-Null
    Copy-Item -LiteralPath $State.configPath -Destination (Join-Path $snapshot 'config') -Force
    $signedRosterPath = Join-Path (Split-Path -Parent $State.configPath) 'signed-rosters.json'
    Copy-Item -LiteralPath $signedRosterPath -Destination (Join-Path $snapshot 'signed-rosters.json') -Force
    if ($State.service.binaryPresent) {
        Copy-Item -LiteralPath $State.binaryPath -Destination (Join-Path $snapshot 'binary') -Force
    }
    $companions = [ordered]@{}
    if ($null -ne $Target.deployment.companionPaths) {
        foreach ($property in $Target.deployment.companionPaths.PSObject.Properties) {
            $path = RequireAbsolutePath $property.Value "companionPaths[$($property.Name)]"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $backup = Join-Path $snapshot ('companion-' + (ShaText $property.Name))
                Copy-Item -LiteralPath $path -Destination $backup -Force
                $companions[$property.Name] = $backup
            }
        }
    }
    $raw = [ordered]@{
        service = PublicService $State.service
        serviceDefinition = $State.service._definition
        config = $State.config
        network = PublicNetwork $State.network
        binaryPath = $State.binaryPath
        configPath = $State.configPath
        signedRosterPath = $signedRosterPath
        companions = $companions
    }
    $statePath = Join-Path $snapshot 'state.json'
    AtomicJson $statePath $raw
    [IO.File]::WriteAllText((Join-Path $snapshot 'routes.json'), $State.network._routesJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $snapshot 'resolver.json'), $State.network._resolverJson, [Text.UTF8Encoding]::new($false))
    AtomicJson (Join-Path $snapshot 'processes.json') @($State.service._processes)
    AtomicJson (Join-Path $snapshot 'status.json') $State.status
    return [ordered]@{
        durable = $true
        service = PublicService $State.service
        config = $State.config
        network = PublicNetwork $State.network
        serviceReceiptSha256 = ShaText (CanonicalJson (PublicService $State.service))
        configReceiptSha256 = ShaText (CanonicalJson $State.config)
        routesReceiptSha256 = ShaFile (Join-Path $snapshot 'routes.json')
        resolverReceiptSha256 = ShaFile (Join-Path $snapshot 'resolver.json')
        processesReceiptSha256 = ShaFile (Join-Path $snapshot 'processes.json')
        statusReceiptSha256 = ShaFile (Join-Path $snapshot 'status.json')
    }
}

function ExtractPayload([string]$Artifact, [string]$Transaction, $Expected) {
    $candidate = Join-Path $Transaction 'candidate.exe'
    $companions = @{}
    $payload = $Expected.installPayload
    if ($payload.format -eq 'executable') {
        Copy-Item -LiteralPath $Artifact -Destination $candidate -Force
    } elseif ($payload.format -eq 'zip') {
        $expanded = Join-Path $Transaction 'expanded'
        Expand-Archive -LiteralPath $Artifact -DestinationPath $expanded -Force
        $source = [IO.Path]::GetFullPath((Join-Path $expanded ([string]$payload.executableMember)))
        if (!$source.StartsWith([IO.Path]::GetFullPath($expanded), [StringComparison]::OrdinalIgnoreCase)) {
            Fail 'candidate executable archive member escapes extraction root'
        }
        Copy-Item -LiteralPath $source -Destination $candidate -Force
        foreach ($companion in @($payload.companions)) {
            $companionSource = [IO.Path]::GetFullPath((Join-Path $expanded ([string]$companion.member)))
            if (!$companionSource.StartsWith([IO.Path]::GetFullPath($expanded), [StringComparison]::OrdinalIgnoreCase)) {
                Fail 'candidate companion archive member escapes extraction root'
            }
            $output = Join-Path $Transaction ('companion-' + (ShaText ([string]$companion.member)))
            Copy-Item -LiteralPath $companionSource -Destination $output -Force
            $companions[[string]$companion.member] = $output
        }
    } else {
        Fail 'unsupported Windows install payload'
    }
    if ((ShaFile $candidate) -ne [string]$Expected.installedBinarySha256) {
        Fail 'extracted candidate executable hash mismatch'
    }
    foreach ($companion in @($payload.companions)) {
        if ((ShaFile $companions[[string]$companion.member]) -ne [string]$companion.sha256) {
            Fail 'extracted candidate companion hash mismatch'
        }
    }
    return [ordered]@{ candidate = $candidate; companions = $companions }
}

function AtomicInstall([string]$Source, [string]$Destination) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    $temporary = Join-Path (Split-Path -Parent $Destination) ('.' + [IO.Path]::GetFileName($Destination) + '.fleet-' + $PID)
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
}

function WaitService([string]$Name, [bool]$Running) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        $service = GetServiceObject $Name
        $actual = $null -ne $service -and $service.State -eq 'Running'
        if ($actual -eq $Running) { return }
        Start-Sleep -Milliseconds 250
    }
    Fail "$Name did not reach the expected state"
}

function WaitServiceDeleted([string]$Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -eq (GetServiceObject $Name)) { return }
        Start-Sleep -Milliseconds 250
    }
    Fail "$Name was not deleted"
}

function AggregateCounters($Status) {
    $tx = [uint64]0
    $rx = [uint64]0
    $peers = @($Status.daemon.state.peers)
    if ($peers.Count -eq 0) { $peers = @($Status.peers) }
    foreach ($peer in $peers) {
        $txValue = if ($null -ne $peer.fips_bytes_sent) { $peer.fips_bytes_sent } else { $peer.tx_bytes }
        $rxValue = if ($null -ne $peer.fips_bytes_recv) { $peer.fips_bytes_recv } else { $peer.rx_bytes }
        $tx += [uint64]$(if ($null -ne $txValue) { $txValue } else { 0 })
        $rx += [uint64]$(if ($null -ne $rxValue) { $rxValue } else { 0 })
    }
    return [ordered]@{ tx = $tx; rx = $rx }
}

function DnsProbe([string]$Name) {
    $answers = @(
        Resolve-DnsName -Name $Name -ErrorAction Stop |
            Where-Object { $null -ne $_.IPAddress } |
            ForEach-Object { [string]$_.IPAddress } |
            Sort-Object -Unique
    )
    if ($answers.Count -eq 0) { Fail "DNS returned no answer for $Name" }
    return [ordered]@{
        answers = $answers
        receipt = ShaText (CanonicalJson ([ordered]@{ name = $Name; answers = $answers }))
    }
}

function DirectProbe([string]$Url) {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    $status = [int]$response.StatusCode
    if ($status -lt 200 -or $status -ge 400) { Fail "Direct URL returned HTTP $status" }
    return [ordered]@{
        status = $status
        receipt = ShaText (CanonicalJson ([ordered]@{
            url = $Url
            status = $status
            bodySha256 = ShaText ([string]$response.Content)
        }))
    }
}

function RestoreTransaction([string]$Transaction, $Target, [string]$TransactionId) {
    AssertElevated
    $snapshot = Join-Path $Transaction 'snapshot'
    $statePath = Join-Path $snapshot 'state.json'
    if (!(Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Fail 'durable rollback snapshot is missing'
    }
    $raw = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $name = ResolveNvpnServiceName $Target.deployment
    $binary = [string]$raw.binaryPath
    $config = [string]$raw.configPath
    $signedRosterPath = [string]$raw.signedRosterPath
    $prior = $raw.service
    if ($prior.installed -and !$prior.binaryPresent) {
        Fail 'cannot safely roll back an installed Windows service whose prior binary was absent'
    }
    WriteJournal $Transaction $Target.id $TransactionId 'rolling-back' | Out-Null
    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
    if (!$prior.installed) {
        $deleteOutput = & sc.exe delete $name 2>&1
        $deleteExit = $LASTEXITCODE
        if ($deleteExit -ne 0 -and $null -ne (GetServiceObject $name)) {
            Fail "rollback failed to delete candidate-created service: $($deleteOutput -join "`n")"
        }
        WaitServiceDeleted $name
    }
    if ($prior.binaryPresent) {
        AtomicInstall (Join-Path $snapshot 'binary') $binary
    } else {
        Remove-Item -LiteralPath $binary -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath (Join-Path $snapshot 'config') -Destination $config -Force
    Copy-Item -LiteralPath (Join-Path $snapshot 'signed-rosters.json') -Destination $signedRosterPath -Force
    if ($prior.installed -and $null -eq (GetServiceObject $name)) {
        Fail 'rollback cannot recreate a missing prior Windows service definition safely'
    }
    if ($null -ne $Target.deployment.companionPaths) {
        foreach ($property in $Target.deployment.companionPaths.PSObject.Properties) {
            $destination = RequireAbsolutePath $property.Value "companionPaths[$($property.Name)]"
            $backup = $raw.companions.($property.Name)
            if (![string]::IsNullOrWhiteSpace([string]$backup)) {
                AtomicInstall ([string]$backup) $destination
            } else {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($prior.installed) {
        $startup = if ($prior.enabled) { 'Automatic' } else { [string]$raw.serviceDefinition.StartMode }
        if ($startup -eq 'Auto') { $startup = 'Automatic' }
        if ($startup -eq 'Demand') { $startup = 'Manual' }
        Set-Service -Name $name -StartupType $startup
        if ($prior.running) {
            Start-Service -Name $name
            WaitService $name $true
        } else {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        }
    }
    $after = Capture $Target $Target.checks
    $afterPublic = [ordered]@{
        service = PublicService $after.service
        config = $after.config
        network = PublicNetwork $after.network
    }
    $expectedPublic = [ordered]@{
        service = $raw.service
        config = $raw.config
        network = $raw.network
    }
    if ((CanonicalJson $afterPublic) -ne (CanonicalJson $expectedPublic)) {
        Fail 'rollback did not restore the exact service/config/network snapshot'
    }
    $journalHash = WriteJournal $Transaction $Target.id $TransactionId 'rolled-back'
    return [ordered]@{
        schema = 2
        targetId = [string]$Target.id
        machineIdentitySha256 = MachineIdentity
        remoteBuildPerformed = $false
        transaction = [ordered]@{
            id = $TransactionId
            state = 'rolled-back'
            durableJournal = $true
            journalReceiptSha256 = $journalHash
        }
        service = $afterPublic.service
        config = $afterPublic.config
        network = $afterPublic.network
        snapshotReceiptSha256 = ShaFile $statePath
        serviceReceiptSha256 = ShaText (CanonicalJson $afterPublic.service)
        configReceiptSha256 = ShaText (CanonicalJson $afterPublic.config)
        routesReceiptSha256 = ShaText $after.network._routesJson
        resolverReceiptSha256 = ShaText $after.network._resolverJson
        processesReceiptSha256 = ShaText (CanonicalJson @($after.service._processes))
    }
}

function InstallCandidate($Payload, $Target, $Expected) {
    AssertElevated
    if ($Target.deployment.authorization -ne 'install') {
        Fail 'target inventory does not authorize install'
    }
    $transactionId = [string]$Expected.transactionId
    $root = RequireAbsolutePath $(if ($Target.deployment.transactionRoot) { $Target.deployment.transactionRoot } else { Join-Path $env:ProgramData 'nvpn\fleet-canary' }) 'transactionRoot'
    $transaction = Join-Path $root $transactionId
    if (Test-Path -LiteralPath $transaction) { Fail 'transaction id already exists' }
    $stageName = [string]$Payload.stageName
    if ([string]::IsNullOrWhiteSpace($stageName) -or $stageName.Contains('\') -or $stageName.Contains('/')) {
        Fail 'staged artifact name is invalid'
    }
    $stage = Join-Path $HOME $stageName
    if (!(Test-Path -LiteralPath $stage -PathType Leaf)) { Fail 'staged artifact is missing' }
    if ((ShaFile $stage) -ne [string]$Expected.artifactSha256) { Fail 'staged artifact SHA-256 mismatch' }
    if ((Get-Item -LiteralPath $stage).Length -ne [int64]$Expected.artifactSize) { Fail 'staged artifact size mismatch' }
    $before = Capture $Target $Target.checks
    AssertExpected $before $Target $Expected
    if ($before.service.installed -and !$before.service.binaryPresent) {
        Fail 'cannot safely canary an installed Windows service whose binary is absent'
    }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $snapshot = SnapshotTransaction $transaction $before $Target
    WriteJournal $transaction $Target.id $transactionId 'preparing' | Out-Null
    $extracted = ExtractPayload $stage $transaction $Expected
    Remove-Item -LiteralPath $stage -Force
    $name = [string]$before.serviceName
    $binary = [string]$before.binaryPath
    $config = [string]$before.configPath
    WriteJournal $transaction $Target.id $transactionId 'installing' | Out-Null
    try {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        AtomicInstall $extracted.candidate $binary
        foreach ($companion in @($Expected.installPayload.companions)) {
            $member = [string]$companion.member
            $destination = $Target.deployment.companionPaths.$member
            if ([string]::IsNullOrWhiteSpace([string]$destination)) {
                Fail "no install destination for companion $member"
            }
            AtomicInstall $extracted.companions[$member] (RequireAbsolutePath $destination "companionPaths[$member]")
        }
        if ($before.service.installed) {
            $normalizedBinary = $binary.Trim('"').ToLowerInvariant()
            if (!$before.service._pathName.ToLowerInvariant().Contains($normalizedBinary)) {
                Fail 'installed Windows service does not use the frozen binary path'
            }
            Set-Service -Name $name -StartupType Automatic
            Start-Service -Name $name
        } else {
            & $binary service install --config $config --force 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail 'candidate failed to install Windows service' }
        }
        WaitService $name $true
        $first = Capture $Target $Target.checks
        $firstPid = [int]$first.service.pid
        $beforeCounters = AggregateCounters $first.status
        $payloadTarget = [string]$Target.checks.payloadTarget
        $pingOutput = & ping.exe -n 1 -w 3000 $payloadTarget 2>&1
        if ($LASTEXITCODE -ne 0) { Fail "payload ping failed: $($pingOutput -join "`n")" }
        $payloadReceipt = ShaText (CanonicalJson ([ordered]@{ target = $payloadTarget; output = @($pingOutput) }))
        $dnsBefore = DnsProbe ([string]$Target.checks.dnsName)
        $directBefore = DirectProbe ([string]$Target.checks.directUrl)
        $statusAfterPayload = InvokeNvpnJson $binary @('status', '--config', $config, '--json', '--discover-secs', '0')
        $afterCounters = AggregateCounters $statusAfterPayload
        Restart-Service -Name $name -Force
        WaitService $name $true
        $final = Capture $Target $Target.checks
        $finalPid = [int]$final.service.pid
        $dnsAfter = DnsProbe ([string]$Target.checks.dnsName)
        $directAfter = DirectProbe ([string]$Target.checks.directUrl)
        if ((CanonicalJson $before.config) -ne (CanonicalJson $final.config)) {
            Fail 'install mutated config or roster identity'
        }
        if ((CanonicalJson (PublicNetwork $before.network)) -ne (CanonicalJson (PublicNetwork $final.network))) {
            Fail 'Direct resolver/route state was not restored after restart'
        }
        $version = InvokeNvpnJson $binary @('version', '--json')
        if ([string]$version.version -ne [string]$Expected.appVersion) { Fail 'installed nvpn version mismatch' }
        $expectedFips = "$($Expected.fipsVersion) (rev $(([string]$Expected.fipsGitSha).Substring(0, 10)))"
        if ([string]$version.fips_core_version -ne $expectedFips) { Fail 'installed FIPS core version mismatch' }
        $journalHash = WriteJournal $transaction $Target.id $transactionId 'committed'
        $meshReady = [bool]$statusAfterPayload.mesh_ready -or [bool]$statusAfterPayload.daemon.state.mesh_ready
        return [ordered]@{
            schema = 2
            targetId = [string]$Target.id
            platform = [string]$Target.platform
            arch = [string]$Target.arch
            machineIdentitySha256 = MachineIdentity
            realChecks = $true
            mocked = $false
            remoteBuildPerformed = $false
            installAuthorized = $true
            appGitSha = [string]$Expected.appGitSha
            appGitTree = [string]$Expected.appGitTree
            appVersion = [string]$Expected.appVersion
            fipsGitSha = [string]$Expected.fipsGitSha
            fipsGitTree = [string]$Expected.fipsGitTree
            fipsVersion = [string]$Expected.fipsVersion
            artifactSha256 = [string]$Expected.artifactSha256
            artifactSize = [int64]$Expected.artifactSize
            stagedArtifactSha256 = [string]$Expected.artifactSha256
            transaction = [ordered]@{
                id = $transactionId
                state = 'committed'
                durableJournal = $true
                rollbackAvailable = $true
                journalReceiptSha256 = $journalHash
                snapshot = $snapshot
            }
            service = [ordered]@{
                installed = $true
                enabled = $true
                running = $true
                restartDurable = $firstPid -ne $finalPid
                binarySha256 = [string]$final.service.binarySha256
                binaryVersion = "nvpn $($version.version)"
                fipsCoreVersion = [string]$version.fips_core_version
                priorInstalled = [bool]$before.service.installed
                priorEnabled = [bool]$before.service.enabled
                priorRunning = [bool]$before.service.running
                priorBinaryPresent = [bool]$before.service.binaryPresent
                priorBinarySha256 = $before.service.binarySha256
                processCount = [int]$final.service.processCount
                pidBeforeRestart = $firstPid
                pidAfterRestart = $finalPid
            }
            config = [ordered]@{
                mutationOutsideInstall = $false
                sha256Before = [string]$before.config.sha256
                sha256After = [string]$final.config.sha256
                signedRosterStoreSha256Before = [string]$before.config.signedRosterStoreSha256
                signedRosterStoreSha256After = [string]$final.config.signedRosterStoreSha256
                rosterIdentitySha256Before = [string]$before.config.rosterIdentitySha256
                rosterIdentitySha256After = [string]$final.config.rosterIdentitySha256
                rosterPeerCountBefore = [int]$before.config.rosterPeerCount
                rosterPeerCountAfter = [int]$final.config.rosterPeerCount
                localDeviceIdentitySha256Before = [string]$before.config.localDeviceIdentitySha256
                localDeviceIdentitySha256After = [string]$final.config.localDeviceIdentitySha256
                networkIdentitySha256Before = [string]$before.config.networkIdentitySha256
                networkIdentitySha256After = [string]$final.config.networkIdentitySha256
            }
            roster = [ordered]@{
                meshReady = $meshReady
                expectedPeerCount = [int]$final.config.rosterPeerCount
                connectedPeerCount = [int]$statusAfterPayload.peer_count
                payloadTarget = $payloadTarget
                payloadSuccess = $true
                txIncreased = [uint64]$afterCounters.tx -gt [uint64]$beforeCounters.tx
                rxIncreased = [uint64]$afterCounters.rx -gt [uint64]$beforeCounters.rx
                txBytesBefore = [uint64]$beforeCounters.tx
                txBytesAfter = [uint64]$afterCounters.tx
                rxBytesBefore = [uint64]$beforeCounters.rx
                rxBytesAfter = [uint64]$afterCounters.rx
                payloadReceiptSha256 = $payloadReceipt
            }
            network = [ordered]@{
                directMode = [bool]$final.network.directMode
                wireguardExitEnabled = [bool]$final.network.wireguardExitEnabled
                dnsResolvedBefore = @($dnsBefore.answers).Count -gt 0
                dnsResolvedAfter = @($dnsAfter.answers).Count -gt 0
                dnsRestored = $before.network.resolverFingerprint -eq $final.network.resolverFingerprint
                defaultRouteRestored = $before.network.defaultRouteFingerprint -eq $final.network.defaultRouteFingerprint
                routeTableRestored = $before.network.routeTableFingerprint -eq $final.network.routeTableFingerprint
                publicInternetAfter = [bool]$final.network.publicInternet
                dnsName = [string]$Target.checks.dnsName
                dnsAnswerCount = [int]@($dnsAfter.answers).Count
                directUrl = [string]$Target.checks.directUrl
                directHttpStatus = [int]$directAfter.status
                resolverFingerprintBefore = [string]$before.network.resolverFingerprint
                resolverFingerprintAfter = [string]$final.network.resolverFingerprint
                defaultRouteFingerprintBefore = [string]$before.network.defaultRouteFingerprint
                defaultRouteFingerprintAfter = [string]$final.network.defaultRouteFingerprint
                routeTableFingerprintBefore = [string]$before.network.routeTableFingerprint
                routeTableFingerprintAfter = [string]$final.network.routeTableFingerprint
                ownedRouteCountAfter = [int]$final.network.ownedRouteCount
                ownedResolverArtifactCountAfter = [int]$final.network.ownedResolverArtifactCount
                dnsReceiptSha256 = ShaText (CanonicalJson @($dnsBefore.receipt, $dnsAfter.receipt))
                directProbeReceiptSha256 = ShaText (CanonicalJson @($directBefore.receipt, $directAfter.receipt))
                routesReceiptSha256 = ShaText $final.network._routesJson
                resolverReceiptSha256 = ShaText $final.network._resolverJson
                processesReceiptSha256 = ShaText (CanonicalJson @($final.service._processes))
            }
        }
    } catch {
        try { RestoreTransaction $transaction $Target $transactionId | Out-Null } catch {
            [Console]::Error.WriteLine("automatic rollback also failed: $_")
        }
        throw
    }
}

try {
    $payloadBytes = [Convert]::FromBase64String($script:FleetPayloadB64)
    $payload = [Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
    if ($payload.protocol -ne 'nvpn-fleet-ssh-transactional-v2') {
        Fail 'fleet protocol mismatch'
    }
    $target = $payload.target
    $action = [string]$payload.action
    $transactionRoot = RequireAbsolutePath $(if ($target.deployment.transactionRoot) { $target.deployment.transactionRoot } else { Join-Path $env:ProgramData 'nvpn\fleet-canary' }) 'transactionRoot'
    if ($action -eq 'probe') {
        $state = Capture $target $target.checks
        $pending = @(PendingTransactions $transactionRoot)
        $result = [ordered]@{
            schema = 2
            targetId = [string]$target.id
            reachable = $true
            platform = [string]$target.platform
            arch = [string]$target.arch
            machineIdentitySha256 = MachineIdentity
            realChecks = $true
            mocked = $false
            remoteBuildPerformed = $false
            transaction = [ordered]@{
                recoveryRequired = $pending.Count -gt 0
                pendingTransactionIds = $pending
            }
            service = PublicService $state.service
            config = $state.config
            network = PublicNetwork $state.network
        }
    } elseif ($action -eq 'install') {
        $result = InstallCandidate $payload $target $payload.expectations
    } elseif ($action -eq 'rollback') {
        $transactionId = [string]$payload.expectations.transactionId
        $result = RestoreTransaction (Join-Path $transactionRoot $transactionId) $target $transactionId
    } else {
        Fail 'unsupported fleet action'
    }
    [Console]::Out.Write((CanonicalJson $result))
} catch {
    [Console]::Error.WriteLine("Windows fleet adapter blocked: $_")
    exit 1
}
