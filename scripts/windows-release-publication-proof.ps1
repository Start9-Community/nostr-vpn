param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedCommit,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedTree,

    [Parameter(Mandatory = $true)]
    [string]$PublishDir,

    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedInstallerSha256,

    [Parameter(Mandatory = $true)]
    [long]$ExpectedInstallerSize,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedAppSha256,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedAppCoreSha256,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedCliSha256,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedWintunSha256
)

$ErrorActionPreference = 'Stop'
Set-Location $RepoPath
$head = (& git rev-parse HEAD).Trim()
$tree = (& git rev-parse 'HEAD^{tree}').Trim()
$status = (& git status --porcelain --untracked-files=all | Out-String).Trim()
if ($head -ne $ExpectedCommit -or $tree -ne $ExpectedTree -or $status) {
    throw 'Windows release source changed after the real platform gate'
}

$files = @{
    app = Join-Path $PublishDir 'NostrVpn.Windows.exe'
    appCore = Join-Path $PublishDir 'nostr_vpn_app_core.dll'
    cli = Join-Path $PublishDir 'nvpn.exe'
    wintun = Join-Path $PublishDir 'binaries\wintun.dll'
}
$expected = @{
    app = $ExpectedAppSha256
    appCore = $ExpectedAppCoreSha256
    cli = $ExpectedCliSha256
    wintun = $ExpectedWintunSha256
}
foreach ($name in $files.Keys) {
    if (!(Test-Path -LiteralPath $files[$name] -PathType Leaf)) {
        throw "Windows gated payload is missing: $name"
    }
    $actual = (
        Get-FileHash -Algorithm SHA256 -LiteralPath $files[$name]
    ).Hash.ToLowerInvariant()
    if ($actual -ne $expected[$name]) {
        throw "Windows gated payload changed: $name"
    }
}

if (!(Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw 'The exact installer smoke artifact is missing'
}
$installer = Get-Item -LiteralPath $InstallerPath
$installerSha256 = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName
).Hash.ToLowerInvariant()
if (
    $installerSha256 -ne $ExpectedInstallerSha256 -or
    $installer.Length -ne $ExpectedInstallerSize
) {
    throw 'The Windows installer differs from the exact locally retained smoke artifact'
}
$proofId = [Guid]::NewGuid().ToString('N')
$tempDir = Join-Path $env:TEMP "nvpn-gated-x64-cli-$proofId"
New-Item -ItemType Directory -Force -Path (
    Join-Path $tempDir 'binaries'
) | Out-Null
Copy-Item -LiteralPath $files.cli -Destination (
    Join-Path $tempDir 'nvpn.exe'
)
Copy-Item -LiteralPath $files.wintun -Destination (
    Join-Path $tempDir 'binaries\wintun.dll'
)
foreach ($name in @('cli', 'wintun')) {
    $snapshot = if ($name -eq 'cli') {
        Join-Path $tempDir 'nvpn.exe'
    } else {
        Join-Path $tempDir 'binaries\wintun.dll'
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $snapshot).Hash.ToLowerInvariant()
    if ($actual -ne $expected[$name]) {
        throw "Windows gated payload snapshot changed: $name"
    }
}

$installDir = Join-Path $env:TEMP "nvpn-publication-payload-proof-$proofId"
$publishRoot = [IO.Path]::GetFullPath($PublishDir).TrimEnd([char[]]'\/')
$installRoot = [IO.Path]::GetFullPath($installDir).TrimEnd([char[]]'\/')
$comparison = [StringComparison]::OrdinalIgnoreCase
$separator = [IO.Path]::DirectorySeparatorChar
if (
    $installRoot.Equals($publishRoot, $comparison) -or
    $installRoot.StartsWith("$publishRoot$separator", $comparison) -or
    $publishRoot.StartsWith("$installRoot$separator", $comparison)
) {
    throw 'Windows publication proof install directory overlaps the gated publish directory'
}
Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
$setup = Start-Process -FilePath $InstallerPath -ArgumentList @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    "/DIR=$installDir"
) -Wait -PassThru
if ($setup.ExitCode -ne 0) {
    throw "Exact Windows installer exited with code $($setup.ExitCode)"
}

$installed = @{
    app = Join-Path $installDir 'NostrVpn.Windows.exe'
    appCore = Join-Path $installDir 'nostr_vpn_app_core.dll'
    cli = Join-Path $installDir 'nvpn.exe'
    wintun = Join-Path $installDir 'binaries\wintun.dll'
}
try {
    foreach ($name in $installed.Keys) {
        if (!(Test-Path -LiteralPath $installed[$name] -PathType Leaf)) {
            throw "Windows installer omitted the gated payload: $name"
        }
        $actual = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $installed[$name]
        ).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$name]) {
            throw "Windows installer payload differs from the real gate: $name"
        }
    }
} finally {
    $uninstaller = Join-Path $installDir 'unins000.exe'
    if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
        Start-Process -FilePath $uninstaller -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART'
        ) -Wait | Out-Null
    }
    Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Remove-Item -Force $ArchivePath -ErrorAction SilentlyContinue
$archive = [IO.Compression.ZipFile]::Open(
    $ArchivePath,
    [IO.Compression.ZipArchiveMode]::Create
)
try {
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive,
        (Join-Path $tempDir 'nvpn.exe'),
        'nvpn.exe',
        [IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive,
        (Join-Path $tempDir 'binaries\wintun.dll'),
        'binaries/wintun.dll',
        [IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
} finally {
    $archive.Dispose()
}
Remove-Item -Recurse -Force $tempDir
