# Transient elevated Windows adapter for the nvpn fleet canary. The checked-in
# SSH driver prepends $script:FleetPayloadB64 and streams this file through a
# checked transient script. Nothing from this adapter remains on the host.
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
    if (!($Value -is [string]) -or ![IO.Path]::IsPathRooted($Value)) {
        Fail "$Label must be an absolute Windows path"
    }
    if (
        $Value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))' -or
        $Value -match '^\\\\[?.][\\/]'
    ) {
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

function AssertPrivateAdminDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (
        !$item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    ) {
        Fail 'fleet transaction root is not a private administrator directory'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sidType = [Security.Principal.SecurityIdentifier]
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $owner = $acl.GetOwner($sidType).Value
    $allowedOwners = @(
        'S-1-5-18',
        'S-1-5-32-544',
        [string]$identity.User.Value
    )
    if ($owner -notin $allowedOwners) {
        Fail 'fleet transaction root is not administrator-owned'
    }
    if (!$acl.AreAccessRulesProtected) {
        Fail 'fleet transaction root ACL is not protected'
    }
    foreach (
        $rule in $acl.GetAccessRules($true, $true, $sidType)
    ) {
        if (
            $rule.AccessControlType -eq
                [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowedOwners
        ) {
            Fail 'fleet transaction root grants non-administrator access'
        }
    }
}

function CreatePrivateAdminDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        AssertPrivateAdminDirectory $Path
        return
    }
    $parent = Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $parent -PathType Container)) {
        Fail 'fleet transaction root parent does not exist'
    }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($identity.User)
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = (
            [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        )
        foreach (
            $sid in @(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
                $identity.User
            )
        ) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        AssertPrivateAdminDirectory $Path
    } catch {
        Remove-Item `
            -LiteralPath $Path `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
        throw
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

function ParseServiceExecutablePath([string]$PathName) {
    if ([string]::IsNullOrWhiteSpace($PathName)) {
        Fail 'Windows service PathName is empty'
    }
    $value = $PathName.Trim()
    if ($value.StartsWith('"')) {
        $closingQuote = $value.IndexOf('"', 1)
        if ($closingQuote -le 1) {
            Fail 'Windows service PathName has an invalid quoted executable'
        }
        $executable = $value.Substring(1, $closingQuote - 1)
        $remainder = $value.Substring($closingQuote + 1)
        if (
            $remainder.Length -gt 0 -and
            ![char]::IsWhiteSpace($remainder[0])
        ) {
            Fail 'Windows service PathName has text joined to its executable'
        }
    } else {
        $match = [regex]::Match($value, '^\S+')
        if (!$match.Success) {
            Fail 'Windows service PathName lacks an executable'
        }
        $executable = $match.Value
    }
    return RequireAbsolutePath $executable 'service PathName executable'
}

function ServiceSnapshot([string]$Name, [string]$BinaryPath) {
    $service = GetServiceObject $Name
    $installed = $null -ne $service
    $running = $installed -and $service.State -eq 'Running'
    $enabled = $installed -and $service.StartMode -eq 'Auto'
    $processes = @(GetProcessIds)
    $binaryPresent = Test-Path -LiteralPath $BinaryPath -PathType Leaf
    $definition = DefinitionValue $service
    $configuredResolved = RequireAbsolutePath $BinaryPath 'binaryPath'
    $execStartPath = $(if ($installed) {
        ParseServiceExecutablePath ([string]$service.PathName)
    } else {
        $null
    })
    $servicePid = $(if ($running -and [int]$service.ProcessId -gt 0) {
        [int]$service.ProcessId
    } else {
        $null
    })
    $mainProcessExePath = $null
    $mainProcessExeSha256 = $null
    if ($null -ne $servicePid) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$servicePid" `
            -ErrorAction SilentlyContinue
        if (
            $null -ne $process -and
            ![string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)
        ) {
            $mainProcessExePath = RequireAbsolutePath `
                ([string]$process.ExecutablePath) 'service process executable'
            $mainProcessExeSha256 = ShaFile $mainProcessExePath
        }
    }
    return [ordered]@{
        installed = [bool]$installed
        enabled = [bool]$enabled
        running = [bool]$running
        binaryPresent = [bool]$binaryPresent
        binarySha256 = $(if ($binaryPresent) { ShaFile $BinaryPath } else { $null })
        definitionSha256 = $(if ($installed) { ShaText (CanonicalJson $definition) } else { $null })
        processCount = [int]$processes.Count
        pid = $servicePid
        _definition = $definition
        _processes = $processes
        _configuredBinaryResolvedPath = $configuredResolved
        _execStartPath = $execStartPath
        _execStartResolvedPath = $execStartPath
        _mainProcessExePath = $mainProcessExePath
        _mainProcessExeSha256 = $mainProcessExeSha256
    }
}

function AssertServiceRuntimeBinding(
    $Service,
    [string]$BinaryPath,
    [string]$ExpectedBinarySha256,
    [bool]$RequireProcess = $true
) {
    if (!$Service.installed) {
        Fail 'cannot bind an absent Windows service'
    }
    $configured = RequireAbsolutePath $BinaryPath 'binaryPath'
    if (
        ![string]::Equals(
            [string]$Service._configuredBinaryResolvedPath,
            $configured,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Fail 'configured Windows binary path changed'
    }
    $execStart = [string]$Service._execStartPath
    if (
        [string]::IsNullOrWhiteSpace($execStart) -or
        ![string]::Equals(
            $execStart,
            $configured,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Fail 'Windows service PathName executable is not the configured binary'
    }
    $mainProcessPath = $Service._mainProcessExePath
    $mainProcessSha256 = $Service._mainProcessExeSha256
    if ($RequireProcess) {
        if (
            $null -eq $Service.pid -or
            [int]$Service.pid -le 0 -or
            [int]$Service.pid -notin @($Service._processes)
        ) {
            Fail 'Windows service PID is not an nvpn process'
        }
        if (
            [string]::IsNullOrWhiteSpace([string]$mainProcessPath) -or
            ![string]::Equals(
                [string]$mainProcessPath,
                $configured,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Fail 'Windows service PID does not execute the configured binary'
        }
        if ([string]$mainProcessSha256 -ne $ExpectedBinarySha256) {
            Fail 'Windows service process hash is not the expected binary'
        }
    } elseif (
        $null -ne $mainProcessPath -or
        $null -ne $mainProcessSha256
    ) {
        Fail 'stopped Windows service unexpectedly has a bound process'
    }
    return [ordered]@{
        configuredBinaryPath = $configured
        configuredBinaryResolvedPath = $configured
        execStartPath = $execStart
        execStartResolvedPath = $execStart
        mainProcessExePath = $mainProcessPath
        mainProcessExeSha256 = $mainProcessSha256
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

function NetworkSnapshot(
    $Status,
    $Checks,
    [bool]$Connectivity = $true
) {
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
    if ($Connectivity) {
        try {
            $dnsResolved = @(Resolve-DnsName -Name ([string]$Checks.dnsName) -ErrorAction Stop).Count -gt 0
        } catch {}
    }
    $publicInternet = $false
    if ($Connectivity) {
        try {
            $response = Invoke-WebRequest -Uri ([string]$Checks.directUrl) -UseBasicParsing -TimeoutSec 10
            $publicInternet = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
        } catch {}
    }
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

function NetworkIntegrityReceipt($Value) {
    return ShaText (CanonicalJson ([ordered]@{
        directMode = [bool]$Value.directMode
        wireguardExitEnabled = [bool]$Value.wireguardExitEnabled
        resolverFingerprint = [string]$Value.resolverFingerprint
        defaultRouteFingerprint = [string]$Value.defaultRouteFingerprint
        routeTableFingerprint = [string]$Value.routeTableFingerprint
        ownedRouteCount = [int]$Value.ownedRouteCount
        ownedResolverArtifactCount = [int]$Value.ownedResolverArtifactCount
    }))
}

function IdentityInputReceipt([string]$Directory) {
    $rows = @(
        Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop |
            Sort-Object Name |
            ForEach-Object {
                if (
                    $_.PSIsContainer -or
                    ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
                ) {
                    Fail 'candidate identity snapshot contains a non-regular input'
                }
                [ordered]@{
                    name = [string]$_.Name
                    sha256 = ShaFile $_.FullName
                    size = [int64]$_.Length
                }
            }
    )
    return [ordered]@{
        sha256 = ShaText (CanonicalJson $rows)
        count = [int]$rows.Count
    }
}

function PrepareIdentityInputs(
    [string]$ConfigPath,
    [string]$WorkspaceRoot
) {
    $workspace = Join-Path $WorkspaceRoot (
        '.identity-' + [Guid]::NewGuid().ToString('N')
    )
    CreatePrivateAdminDirectory $workspace
    $snapshotConfig = Join-Path $workspace (
        [IO.Path]::GetFileName($ConfigPath)
    )
    try {
        $parent = Split-Path -Parent $ConfigPath
        $fileName = [IO.Path]::GetFileName($ConfigPath)
        $inputs = @(
            $ConfigPath,
            (Join-Path $parent 'signed-rosters.json')
        )
        foreach (
            $suffix in @(
                'nostr-secret-key',
                'wireguard-exit-private-key',
                'wireguard-exit-peer-preshared-key',
                'pending-join-request',
                'cashu-wallet-seed'
            )
        ) {
            $inputs += Join-Path $parent (
                '.' + $fileName + '.' + $suffix + '.dpapi'
            )
        }
        foreach ($source in $inputs) {
            if (!(Test-Path -LiteralPath $source)) { continue }
            $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if (
                $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            ) {
                Fail 'live candidate identity input is not a regular file'
            }
            Copy-Item `
                -LiteralPath $source `
                -Destination (Join-Path $workspace $item.Name) `
                -Force `
                -ErrorAction Stop
        }
        if (!(Test-Path -LiteralPath $snapshotConfig -PathType Leaf)) {
            Fail 'candidate identity config snapshot is missing'
        }
        if (
            !(Test-Path `
                -LiteralPath (Join-Path $workspace 'signed-rosters.json') `
                -PathType Leaf)
        ) {
            Fail 'candidate signed roster snapshot is missing'
        }
        $receipt = IdentityInputReceipt $workspace
        return [pscustomobject]@{
            Path = $workspace
            Config = $snapshotConfig
            Receipt = [string]$receipt.sha256
            Count = [int]$receipt.count
        }
    } catch {
        Remove-Item `
            -LiteralPath $workspace `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
        throw
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

function AssertFreshInstallAuthorization($Expected) {
    $deadline = 0L
    if (
        $null -eq $Expected.rosterFreshnessDeadline -or
        $Expected.rosterFreshnessDeadline -is [bool] -or
        ![long]::TryParse(
            [string]$Expected.rosterFreshnessDeadline,
            [ref]$deadline
        ) -or
        $deadline -le 0
    ) {
        Fail 'roster freshness deadline is invalid'
    }
    $epoch = [DateTime]::SpecifyKind(
        [DateTime]'1970-01-01',
        [DateTimeKind]::Utc
    )
    $now = [long][Math]::Floor(
        ([DateTime]::UtcNow - $epoch).TotalSeconds
    )
    if ($now -gt $deadline) {
        Fail 'fleet roster evidence expired before remote install mutation'
    }
}

function Capture(
    $Target,
    $Checks,
    [string]$IdentityBinary,
    $IdentityExpectations,
    [string]$IdentityWorkspaceRoot
) {
    $deployment = $Target.deployment
    $serviceName = ResolveNvpnServiceName $deployment
    $binary = RequireAbsolutePath $deployment.binaryPath 'binaryPath'
    $config = RequireAbsolutePath $deployment.configPath 'configPath'
    $probeBinary = RequireAbsolutePath $(if ($deployment.probeBinaryPath) { $deployment.probeBinaryPath } else { $binary }) 'probeBinaryPath'
    if (!(Test-Path -LiteralPath $probeBinary -PathType Leaf)) {
        Fail "probe CLI does not exist: $probeBinary"
    }
    if (!(Test-Path -LiteralPath $IdentityBinary -PathType Leaf)) {
        Fail "candidate identity CLI does not exist: $IdentityBinary"
    }
    $candidateHash = ShaFile $IdentityBinary
    if (
        $candidateHash -ne
        [string]$IdentityExpectations.installedBinarySha256
    ) {
        Fail 'candidate identity CLI hash mismatch'
    }
    $candidateSize = [int64](Get-Item -LiteralPath $IdentityBinary).Length
    if ($candidateSize -le 0) {
        Fail 'candidate identity CLI is empty'
    }
    $candidateVersion = InvokeNvpnJson $IdentityBinary @('version', '--json')
    $expectedFips = "$($IdentityExpectations.fipsVersion) (rev $(([string]$IdentityExpectations.fipsGitSha).Substring(0, 10)))"
    if (
        [string]$candidateVersion.version -ne
        [string]$IdentityExpectations.appVersion
    ) {
        Fail 'candidate identity CLI app version mismatch'
    }
    if ([string]$candidateVersion.fips_core_version -ne $expectedFips) {
        Fail 'candidate identity CLI FIPS version mismatch'
    }
    $probeHashBefore = ShaFile $probeBinary
    $probeVersion = InvokeNvpnJson $probeBinary @('version', '--json')
    if (
        [string]::IsNullOrWhiteSpace([string]$probeVersion.version) -or
        [string]::IsNullOrWhiteSpace([string]$probeVersion.fips_core_version)
    ) {
        Fail 'probe CLI version receipt is incomplete'
    }
    $installedStatusBefore = InvokeNvpnJson $probeBinary @('status', '--config', $config, '--json', '--discover-secs', '0')
    $serviceBefore = ServiceSnapshot $serviceName $binary
    $networkBefore = NetworkSnapshot $installedStatusBefore $Checks $false
    $configHashBefore = ShaFile $config
    $signedRosters = Join-Path (Split-Path -Parent $config) 'signed-rosters.json'
    if (!(Test-Path -LiteralPath $signedRosters -PathType Leaf)) {
        Fail "signed roster store is missing: $signedRosters"
    }
    $signedRosterHashBefore = ShaFile $signedRosters
    $identityInputs = PrepareIdentityInputs $config $IdentityWorkspaceRoot
    try {
        $candidateStatus = InvokeNvpnJson $IdentityBinary @(
            'status',
            '--config',
            [string]$identityInputs.Config,
            '--json',
            '--discover-secs',
            '0'
        )
        $identityInputsAfter = IdentityInputReceipt $identityInputs.Path
    } finally {
        Remove-Item `
            -LiteralPath $identityInputs.Path `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $identityInputs.Path) {
        Fail 'candidate identity snapshot cleanup left residue'
    }
    if (
        [string]$identityInputsAfter.sha256 -ne
            [string]$identityInputs.Receipt -or
        [int]$identityInputsAfter.count -ne [int]$identityInputs.Count
    ) {
        Fail 'candidate identity status mutated its private input snapshot'
    }
    $configValue = ConfigSnapshot $config $candidateStatus
    $installedStatusAfter = InvokeNvpnJson $probeBinary @('status', '--config', $config, '--json', '--discover-secs', '0')
    $serviceAfter = ServiceSnapshot $serviceName $binary
    $networkAfter = NetworkSnapshot $installedStatusAfter $Checks
    $probeHashAfter = ShaFile $probeBinary
    $candidateHashAfter = ShaFile $IdentityBinary
    $configHashAfter = ShaFile $config
    $signedRosterHashAfter = ShaFile $signedRosters
    $serviceBeforeReceipt = ShaText (CanonicalJson (PublicService $serviceBefore))
    $serviceAfterReceipt = ShaText (CanonicalJson (PublicService $serviceAfter))
    $networkBeforeReceipt = NetworkIntegrityReceipt $networkBefore
    $networkAfterReceipt = NetworkIntegrityReceipt $networkAfter
    if ($probeHashAfter -ne $probeHashBefore) {
        Fail 'candidate identity status mutated the installed probe CLI'
    }
    if ($candidateHashAfter -ne $candidateHash) {
        Fail 'candidate identity CLI changed while executing status'
    }
    if ($serviceAfterReceipt -ne $serviceBeforeReceipt) {
        Fail 'candidate identity status mutated the nvpn service'
    }
    if ($configHashAfter -ne $configHashBefore) {
        Fail 'candidate identity status mutated the nvpn config'
    }
    if ($signedRosterHashAfter -ne $signedRosterHashBefore) {
        Fail 'candidate identity status mutated the signed roster store'
    }
    if ($networkAfterReceipt -ne $networkBeforeReceipt) {
        Fail 'candidate identity status mutated network state'
    }
    return [ordered]@{
        service = $serviceAfter
        config = $configValue
        network = $networkAfter
        status = $installedStatusAfter
        probeBinarySha256 = $probeHashAfter
        probeAppVersion = [string]$probeVersion.version
        probeFipsCoreVersion = [string]$probeVersion.fips_core_version
        identityOracle = [ordered]@{
            kind = 'exact-candidate-read-only-status-v1'
            readOnly = $true
            statusDiscoverSecs = 0
            candidateBinarySha256 = $candidateHashAfter
            candidateBinarySize = $candidateSize
            candidateAppVersion = [string]$candidateVersion.version
            candidateFipsCoreVersion = [string]$candidateVersion.fips_core_version
            candidateStatusReceiptSha256 = ShaText (CanonicalJson $candidateStatus)
            identityInputBeforeSha256 = [string]$identityInputs.Receipt
            identityInputAfterSha256 = [string]$identityInputsAfter.sha256
            identityInputCount = [int]$identityInputs.Count
            identitySnapshotRemoved = $true
            installedObservationBinarySha256 = $probeHashAfter
            serviceBeforeSha256 = $serviceBeforeReceipt
            serviceAfterSha256 = $serviceAfterReceipt
            configBeforeSha256 = $configHashBefore
            configAfterSha256 = $configHashAfter
            signedRosterStoreBeforeSha256 = $signedRosterHashBefore
            signedRosterStoreAfterSha256 = $signedRosterHashAfter
            networkBeforeSha256 = $networkBeforeReceipt
            networkAfterSha256 = $networkAfterReceipt
        }
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
    $preinstallProbe = $Expected.preinstallProbe
    if (
        [string]$State.probeBinarySha256 -ne
        [string]$preinstallProbe.probeBinarySha256
    ) {
        Fail 'probe CLI binary changed after preflight'
    }
    if (
        [string]$State.probeAppVersion -ne
        [string]$preinstallProbe.probeAppVersion
    ) {
        Fail 'probe CLI app version changed after preflight'
    }
    if (
        [string]$State.probeFipsCoreVersion -ne
        [string]$preinstallProbe.probeFipsCoreVersion
    ) {
        Fail 'probe CLI FIPS version changed after preflight'
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
    if ($State.service.installed) {
        if (!$State.service.binaryPresent) {
            Fail 'cannot safely canary an installed Windows service whose binary is absent'
        }
        $transition = if (
            [string]$State.service.binarySha256 -eq
            [string]$Expected.installedBinarySha256
        ) {
            'reinstalled-exact'
        } else {
            'candidate-transition'
        }
    } else {
        $transition = 'fresh-install'
    }
    if ([string]$Expected.installTransition -ne $transition) {
        Fail 'install transition does not match the preinstall service state'
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
    if (Test-Path -LiteralPath $snapshot) {
        Fail 'transaction snapshot already exists'
    }
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

function RestoreTransaction(
    [string]$Transaction,
    $Target,
    [string]$TransactionId,
    $Expected
) {
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
    $after = Capture `
        $Target `
        $Target.checks `
        (Join-Path $Transaction 'candidate.exe') `
        $Expected `
        $Transaction
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
    foreach (
        $field in @(
            'installed',
            'enabled',
            'running',
            'binaryPresent',
            'binarySha256',
            'definitionSha256',
            'processCount'
        )
    ) {
        if (
            (CanonicalJson $afterPublic.service.$field) -ne
            (CanonicalJson $expectedPublic.service.$field)
        ) {
            Fail "rollback did not restore service field $field"
        }
    }
    if ($prior.running) {
        if ($null -eq $afterPublic.service.pid -or [int]$afterPublic.service.pid -le 0) {
            Fail 'rollback did not restart the restored Windows service'
        }
        if ([int]$afterPublic.service.pid -eq [int]$expectedPublic.service.pid) {
            Fail 'rollback did not prove a new restored Windows service process'
        }
    } elseif ($null -ne $afterPublic.service.pid) {
        Fail 'rollback unexpectedly started a previously stopped Windows service'
    }
    if ((CanonicalJson $afterPublic.config) -ne (CanonicalJson $expectedPublic.config)) {
        Fail 'rollback did not restore the exact config snapshot'
    }
    if ((CanonicalJson $afterPublic.network) -ne (CanonicalJson $expectedPublic.network)) {
        Fail 'rollback did not restore the exact network snapshot'
    }
    $runtimeBinding = $null
    if ($prior.installed) {
        $runtimeBinding = AssertServiceRuntimeBinding `
            $after.service `
            $binary `
            ([string]$prior.binarySha256) `
            ([bool]$prior.running)
    }
    $restoredService = PublicService $after.service
    if ($null -ne $runtimeBinding) {
        foreach (
            $field in @(
                'configuredBinaryPath',
                'configuredBinaryResolvedPath',
                'execStartPath',
                'execStartResolvedPath',
                'mainProcessExePath',
                'mainProcessExeSha256'
            )
        ) {
            $restoredService[$field] = $runtimeBinding.$field
        }
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
        service = $restoredService
        config = $afterPublic.config
        network = $afterPublic.network
        snapshotReceiptSha256 = ShaFile $statePath
        serviceReceiptSha256 = ShaText (CanonicalJson $restoredService)
        configReceiptSha256 = ShaText (CanonicalJson $afterPublic.config)
        routesReceiptSha256 = ShaText $after.network._routesJson
        resolverReceiptSha256 = ShaText $after.network._resolverJson
        processesReceiptSha256 = ShaText (CanonicalJson @($after.service._processes))
    }
}

function RemoveStagedArtifact([string]$Path) {
    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    try {
        $items = @(
            Get-ChildItem -LiteralPath $parent -Force -Filter $leaf `
                -ErrorAction Stop |
                Where-Object { $_.Name -ceq $leaf }
        )
        if ($items.Count -gt 1) {
            Fail 'staged artifact path is ambiguous'
        }
        if ($items.Count -eq 1) {
            $item = $items[0]
            if (
                $item.PSIsContainer -and
                !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            ) {
                Fail 'staged artifact path is not a regular file'
            }
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    } catch {
        Fail "staged artifact cleanup failed: $_"
    }
    $remaining = @(
        Get-ChildItem -LiteralPath $parent -Force -Filter $leaf `
            -ErrorAction Stop |
            Where-Object { $_.Name -ceq $leaf }
    )
    if ($remaining.Count -ne 0) {
        Fail 'staged artifact cleanup left remote residue'
    }
}

function CopyStagedArtifact(
    [string]$Stage,
    [string]$Root,
    [string]$TransactionId,
    [string]$Suffix = ''
) {
    if ($Suffix -notin @('', '.exe')) {
        Fail 'private staged artifact suffix is invalid'
    }
    $rootCreated = !(Test-Path -LiteralPath $Root)
    $private = Join-Path $Root ('.staged-' + $TransactionId + $Suffix)
    $source = $null
    $privateWrite = $null
    $privateLock = $null
    $privateCreated = $false
    $result = $null
    $primary = $null
    try {
        CreatePrivateAdminDirectory $Root
        $stageItem = Get-Item -LiteralPath $Stage -Force -ErrorAction Stop
        if (
            $stageItem.PSIsContainer -or
            ($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
        ) {
            Fail 'staged artifact is not a regular non-reparse file'
        }
        $source = [IO.FileStream]::new(
            $Stage,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $stageItem = Get-Item -LiteralPath $Stage -Force -ErrorAction Stop
        if (
            $stageItem.PSIsContainer -or
            ($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
        ) {
            Fail 'staged artifact is not a regular non-reparse file'
        }
        $privateWrite = [IO.FileStream]::new(
            $private,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read
        )
        $privateCreated = $true
        $source.CopyTo($privateWrite)
        $privateWrite.Flush($true)
        $privateWrite.Dispose()
        $privateWrite = $null
        $privateLock = [IO.FileStream]::new(
            $private,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $result = [pscustomobject]@{
            Path = $private
            Lock = $privateLock
            RootCreated = $rootCreated
        }
    } catch {
        $primary = $_
    }
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    if ($null -ne $source) {
        try { $source.Dispose() } catch {
            $cleanupErrors.Add("source staging handle: $_")
        }
    }
    if ($null -eq $primary -and $cleanupErrors.Count -gt 0) {
        $primary = [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new(
                'source staging handle cleanup failed'
            ),
            'NvpnFleetStageCleanup',
            [Management.Automation.ErrorCategory]::CloseError,
            $Stage
        )
    }
    if ($null -ne $primary) {
        foreach ($stream in @($privateLock, $privateWrite)) {
            if ($null -eq $stream) { continue }
            try { $stream.Dispose() } catch {
                $cleanupErrors.Add("private staging handle: $_")
            }
        }
        if ($privateCreated) {
            try { RemoveStagedArtifact $private } catch {
                $cleanupErrors.Add([string]$_)
            }
        }
        if ($rootCreated) {
            try {
                Remove-Item -LiteralPath $Root -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $Root -ErrorAction Stop) {
                    throw 'private staging directory cleanup left residue'
                }
            } catch {
                $cleanupErrors.Add("private staging directory: $_")
            }
        }
        $details = 'staged artifact could not be secured: ' +
            $primary.Exception.Message
        if ($cleanupErrors.Count -gt 0) {
            $details += '; cleanup also failed: ' +
                ($cleanupErrors -join '; ')
        }
        Fail $details
    }
    return $result
}

function ProbeCandidate($Payload, $Target, $Expected) {
    AssertElevated
    if ([string]$Expected.kind -ne 'candidate-identity-probe-v1') {
        Fail 'candidate probe expectations kind is invalid'
    }
    if ($Expected.requireReadOnly -ne $true) {
        Fail 'candidate probe must require read-only execution'
    }
    $stageName = [string]$Payload.stageName
    if (
        [string]::IsNullOrWhiteSpace($stageName) -or
        $stageName -notmatch '^\.nvpn-fleet-[0-9a-f]{32}\.artifact$'
    ) {
        Fail 'staged candidate probe name is invalid'
    }
    $probeId = [string]$Expected.probeId
    if ($probeId -notmatch '^[0-9a-f]{32}$') {
        Fail 'candidate probe id is invalid'
    }
    $stage = Join-Path $HOME $stageName
    if (!(Test-Path -LiteralPath $stage -PathType Leaf)) {
        Fail 'staged candidate probe executable is missing'
    }
    $candidateSize = [int64]$Payload.candidateBinarySize
    if ($candidateSize -le 0) {
        Fail 'candidate probe executable size is invalid'
    }
    $root = RequireAbsolutePath $(if ($Target.deployment.transactionRoot) {
        $Target.deployment.transactionRoot
    } else {
        Join-Path $env:ProgramData 'nvpn\fleet-canary'
    }) 'transactionRoot'
    $secured = $null
    $result = $null
    $primary = $null
    try {
        $secured = CopyStagedArtifact $stage $root $probeId '.exe'
        if ((ShaFile $secured.Path) -ne [string]$Expected.installedBinarySha256) {
            Fail 'staged candidate probe executable SHA-256 mismatch'
        }
        if ((Get-Item -LiteralPath $secured.Path).Length -ne $candidateSize) {
            Fail 'staged candidate probe executable size mismatch'
        }
        $state = Capture `
            $Target `
            $Target.checks `
            ([string]$secured.Path) `
            $Expected `
            $root
        $pending = @(PendingTransactions $root)
        $result = [ordered]@{
            schema = 2
            targetId = [string]$Target.id
            reachable = $true
            platform = [string]$Target.platform
            arch = [string]$Target.arch
            machineIdentitySha256 = MachineIdentity
            realChecks = $true
            mocked = $false
            remoteBuildPerformed = $false
            probeBinarySha256 = [string]$state.probeBinarySha256
            probeAppVersion = [string]$state.probeAppVersion
            probeFipsCoreVersion = [string]$state.probeFipsCoreVersion
            identityOracle = $state.identityOracle
            transaction = [ordered]@{
                recoveryRequired = $pending.Count -gt 0
                pendingTransactionIds = $pending
            }
            service = PublicService $state.service
            config = $state.config
            network = PublicNetwork $state.network
        }
    } catch {
        $primary = $_
    }
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    if ($null -ne $secured) {
        try { $secured.Lock.Dispose() } catch {
            $cleanupErrors.Add("private staging lock: $_")
        }
        try { RemoveStagedArtifact ([string]$secured.Path) } catch {
            $cleanupErrors.Add([string]$_)
        }
        if ($secured.RootCreated) {
            try {
                Remove-Item -LiteralPath $root -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $root -ErrorAction Stop) {
                    throw 'private staging directory cleanup left residue'
                }
            } catch {
                $cleanupErrors.Add("private staging directory: $_")
            }
        }
    }
    if ($null -ne $primary) {
        if ($cleanupErrors.Count -gt 0) {
            Fail (
                $primary.Exception.Message +
                '; staged candidate probe cleanup also failed: ' +
                ($cleanupErrors -join '; ')
            )
        }
        throw $primary
    }
    if ($cleanupErrors.Count -gt 0) {
        Fail (
            'staged candidate probe cleanup failed: ' +
            ($cleanupErrors -join '; ')
        )
    }
    if ($null -eq $result) {
        Fail 'staged candidate probe returned no result'
    }
    return $result
}

function InstallStagedCandidate($Payload, $Target, $Expected, [string]$Stage) {
    AssertElevated
    if ($Target.deployment.authorization -ne 'install') {
        Fail 'target inventory does not authorize install'
    }
    $transactionId = [string]$Expected.transactionId
    $root = RequireAbsolutePath $(if ($Target.deployment.transactionRoot) { $Target.deployment.transactionRoot } else { Join-Path $env:ProgramData 'nvpn\fleet-canary' }) 'transactionRoot'
    $transaction = Join-Path $root $transactionId
    if (Test-Path -LiteralPath $transaction) { Fail 'transaction id already exists' }
    if ((ShaFile $stage) -ne [string]$Expected.artifactSha256) { Fail 'staged artifact SHA-256 mismatch' }
    if ((Get-Item -LiteralPath $stage).Length -ne [int64]$Expected.artifactSize) { Fail 'staged artifact size mismatch' }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [IO.Directory]::CreateDirectory($transaction) | Out-Null
    try {
        $extracted = ExtractPayload $stage $transaction $Expected
        $before = Capture `
            $Target `
            $Target.checks `
            ([string]$extracted.candidate) `
            $Expected `
            $transaction
        AssertExpected $before $Target $Expected
        if ($before.service.installed) {
            AssertServiceRuntimeBinding `
                $before.service `
                ([string]$before.binaryPath) `
                ([string]$before.service.binarySha256) `
                ([bool]$before.service.running) | Out-Null
        }
        $snapshot = SnapshotTransaction $transaction $before $Target
        WriteJournal $transaction $Target.id $transactionId 'preparing' | Out-Null
    } catch {
        Remove-Item -LiteralPath $transaction -Recurse -Force `
            -ErrorAction SilentlyContinue
        throw
    }
    $name = [string]$before.serviceName
    $binary = [string]$before.binaryPath
    $config = [string]$before.configPath
    WriteJournal $transaction $Target.id $transactionId 'installing' | Out-Null
    try {
        AssertFreshInstallAuthorization $Expected
    } catch {
        $primary = $_
        try {
            Remove-Item -LiteralPath $transaction -Recurse -Force `
                -ErrorAction Stop
            if (Test-Path -LiteralPath $transaction) {
                throw 'expired transaction cleanup left residue'
            }
        } catch {
            Fail (
                $primary.Exception.Message +
                '; expired transaction cleanup also failed: ' +
                $_.Exception.Message
            )
        }
        throw $primary
    }
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
            Set-Service -Name $name -StartupType Automatic
            Start-Service -Name $name
        } else {
            & $binary service install --config $config --force 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail 'candidate failed to install Windows service' }
        }
        WaitService $name $true
        $first = Capture `
            $Target $Target.checks $binary $Expected $transaction
        $firstPid = [int]$first.service.pid
        AssertServiceRuntimeBinding `
            $first.service `
            $binary `
            ([string]$Expected.installedBinarySha256) | Out-Null
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
        $final = Capture `
            $Target $Target.checks $binary $Expected $transaction
        $finalPid = [int]$final.service.pid
        $runtimeBinding = AssertServiceRuntimeBinding `
            $final.service `
            $binary `
            ([string]$Expected.installedBinarySha256)
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
            preinstallProbe = [ordered]@{
                probeBinarySha256 = [string]$before.probeBinarySha256
                probeAppVersion = [string]$before.probeAppVersion
                probeFipsCoreVersion = [string]$before.probeFipsCoreVersion
            }
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
                installTransition = [string]$Expected.installTransition
                processCount = [int]$final.service.processCount
                pidBeforeRestart = $firstPid
                pidAfterRestart = $finalPid
                configuredBinaryPath = [string]$runtimeBinding.configuredBinaryPath
                configuredBinaryResolvedPath = [string]$runtimeBinding.configuredBinaryResolvedPath
                execStartPath = [string]$runtimeBinding.execStartPath
                execStartResolvedPath = [string]$runtimeBinding.execStartResolvedPath
                mainProcessExePath = [string]$runtimeBinding.mainProcessExePath
                mainProcessExeSha256 = [string]$runtimeBinding.mainProcessExeSha256
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
        try {
            RestoreTransaction `
                $transaction $Target $transactionId $Expected | Out-Null
        } catch {
            [Console]::Error.WriteLine("automatic rollback also failed: $_")
        }
        throw
    }
}

function InstallCandidate($Payload, $Target, $Expected) {
    AssertElevated
    $stageName = [string]$Payload.stageName
    if (
        [string]::IsNullOrWhiteSpace($stageName) -or
        $stageName -notmatch
            '^\.nvpn-fleet-[0-9a-f]{32}\.artifact$'
    ) {
        Fail 'staged artifact name is invalid'
    }
    $stage = Join-Path $HOME $stageName
    if (!(Test-Path -LiteralPath $stage -PathType Leaf)) {
        Fail 'staged artifact is missing'
    }
    $transactionId = [string]$Expected.transactionId
    if ($transactionId -notmatch '^[0-9a-f]{32}$') {
        Fail 'transaction id is invalid'
    }
    $root = RequireAbsolutePath $(if ($Target.deployment.transactionRoot) { $Target.deployment.transactionRoot } else { Join-Path $env:ProgramData 'nvpn\fleet-canary' }) 'transactionRoot'
    $transaction = Join-Path $root $transactionId
    if (Test-Path -LiteralPath $transaction) {
        Fail 'transaction id already exists'
    }
    $secured = $null
    $result = $null
    $primary = $null
    try {
        $secured = CopyStagedArtifact $stage $root $transactionId
        $result = InstallStagedCandidate `
            $Payload $Target $Expected $secured.Path
    } catch {
        $primary = $_
    }
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    if ($null -ne $secured) {
        try { $secured.Lock.Dispose() } catch {
            $cleanupErrors.Add("private staging lock: $_")
        }
    }
    foreach ($path in @($(if ($null -ne $secured) { $secured.Path }))) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        try { RemoveStagedArtifact ([string]$path) } catch {
            $cleanupErrors.Add([string]$_)
        }
    }
    if (
        $null -ne $secured -and
        $secured.RootCreated -and
        !(Test-Path -LiteralPath $transaction)
    ) {
        try {
            Remove-Item -LiteralPath $root -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $root -ErrorAction Stop) {
                throw 'private staging directory cleanup left residue'
            }
        } catch {
            $cleanupErrors.Add("private staging directory: $_")
        }
    }
    if ($null -ne $primary) {
        if ($cleanupErrors.Count -gt 0) {
            Fail (
                $primary.Exception.Message +
                '; staged artifact cleanup also failed: ' +
                ($cleanupErrors -join '; ')
            )
        }
        throw $primary
    }
    if ($cleanupErrors.Count -gt 0) {
        Fail ('staged artifact cleanup failed: ' + ($cleanupErrors -join '; '))
    }
    return $result
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
        $result = ProbeCandidate $payload $target $payload.expectations
    } elseif ($action -eq 'install') {
        $result = InstallCandidate $payload $target $payload.expectations
    } elseif ($action -eq 'rollback') {
        $transactionId = [string]$payload.expectations.transactionId
        $result = RestoreTransaction `
            (Join-Path $transactionRoot $transactionId) `
            $target `
            $transactionId `
            $payload.expectations
    } else {
        Fail 'unsupported fleet action'
    }
    [Console]::Out.Write((CanonicalJson $result))
} catch {
    [Console]::Error.WriteLine("Windows fleet adapter blocked: $_")
    exit 1
}
