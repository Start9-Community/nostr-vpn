[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LegacyUninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Nostr VPN'
$script:CurrentUninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{DA4FA554-4718-4E6D-8CE8-E43A05B4B723}_is1'

function ConvertFrom-NvpnUninstallCommand {
    param([Parameter(Mandatory)][string] $Command)

    $trimmed = $Command.Trim()
    if ($trimmed -match '^"([^"]+)"') {
        return $Matches[1]
    }
    if ($trimmed -match '^(\S+)') {
        return $Matches[1]
    }
    throw 'The registered uninstaller command is empty.'
}

function ConvertTo-NvpnCanonicalPath {
    param([Parameter(Mandatory)][string] $Path)

    $trimmed = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'An existing Nostr VPN installation has an empty path.'
    }
    $full = [IO.Path]::GetFullPath($trimmed).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full.Length -le $root.Length) {
        throw 'An existing Nostr VPN installation points at a filesystem root.'
    }
    return $full
}

function Test-NvpnSamePath {
    param(
        [Parameter(Mandatory)][string] $Left,
        [Parameter(Mandatory)][string] $Right
    )

    return [string]::Equals(
        (ConvertTo-NvpnCanonicalPath $Left),
        (ConvertTo-NvpnCanonicalPath $Right),
        [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-NvpnOwnedRegistration {
    param(
        [Parameter(Mandatory)][ValidateSet('legacy', 'current')][string] $Kind,
        [Parameter(Mandatory)][string] $RegistryPath,
        [Parameter(Mandatory)] $Values
    )

    if ([string]$Values.DisplayName -cne 'Nostr VPN') {
        throw "Refusing an unowned registration at $RegistryPath."
    }

    $installLocation = ConvertTo-NvpnCanonicalPath ([string]$Values.InstallLocation)
    if (!(Test-Path -LiteralPath $installLocation -PathType Container)) {
        throw "The registered Nostr VPN directory is missing: $installLocation"
    }

    $uninstaller = ConvertTo-NvpnCanonicalPath (
        ConvertFrom-NvpnUninstallCommand ([string]$Values.UninstallString))
    $expectedUninstallerName = if ($Kind -eq 'legacy') { 'uninstall.exe' } else { 'unins000.exe' }
    $expectedUninstaller = Join-Path $installLocation $expectedUninstallerName
    if (!(Test-NvpnSamePath $uninstaller $expectedUninstaller)) {
        throw "Refusing an uninstaller outside its owned Nostr VPN directory: $uninstaller"
    }
    if (!(Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        throw "The registered Nostr VPN uninstaller is missing: $uninstaller"
    }

    $mainBinaryName = if ($Kind -eq 'legacy') { 'nostr-vpn-gui.exe' } else { 'NostrVpn.Windows.exe' }
    if ($Kind -eq 'legacy' -and [string]$Values.MainBinaryName -cne $mainBinaryName) {
        throw "Refusing a legacy registration with an unexpected main binary at $RegistryPath."
    }

    [pscustomobject]@{
        Kind = $Kind
        RegistryPath = $RegistryPath
        InstallLocation = $installLocation
        Uninstaller = $uninstaller
        MainExecutable = Join-Path $installLocation $mainBinaryName
        RequiresElevation = $Kind -eq 'legacy'
        Arguments = if ($Kind -eq 'legacy') {
            @('/S')
        } else {
            @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        }
    }
}

function Get-NvpnOwnedRegistrations {
    $registrations = @()
    $specifications = @(
        @{ Kind = 'legacy'; Path = "Registry::HKEY_LOCAL_MACHINE\$script:LegacyUninstallKey" },
        @{ Kind = 'legacy'; Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Nostr VPN" },
        @{ Kind = 'current'; Path = "Registry::HKEY_CURRENT_USER\$script:CurrentUninstallKey" }
    )
    foreach ($specification in $specifications) {
        if (Test-Path -LiteralPath $specification.Path) {
            $values = Get-ItemProperty -LiteralPath $specification.Path
            $registrations += Resolve-NvpnOwnedRegistration `
                -Kind $specification.Kind `
                -RegistryPath $specification.Path `
                -Values $values
        }
    }
    return $registrations
}

function Stop-NvpnGuiProcesses {
    Get-Process -Name @('NostrVpn.Windows', 'nostr-vpn-gui') -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 250
    $remaining = Get-Process -Name @('NostrVpn.Windows', 'nostr-vpn-gui') -ErrorAction SilentlyContinue
    if ($remaining) {
        throw 'An existing Nostr VPN window could not be closed.'
    }
}

function Invoke-NvpnOwnedUninstall {
    param(
        [Parameter(Mandatory)] $Registration,
        [scriptblock] $StartUninstaller = {
            param($Item)
            $parameters = @{
                FilePath = $Item.Uninstaller
                ArgumentList = $Item.Arguments
                Wait = $true
                PassThru = $true
            }
            if ($Item.RequiresElevation) {
                $parameters.Verb = 'RunAs'
            }
            (Start-Process @parameters).ExitCode
        },
        [scriptblock] $RegistrationExists = {
            param($Item)
            Test-Path -LiteralPath $Item.RegistryPath
        },
        [scriptblock] $ExecutableExists = {
            param($Item)
            Test-Path -LiteralPath $Item.MainExecutable -PathType Leaf
        }
    )

    $exitCode = & $StartUninstaller $Registration
    if ($exitCode -ne 0) {
        throw "The $($Registration.Kind) Nostr VPN uninstaller exited with code $exitCode."
    }
    if (& $RegistrationExists $Registration) {
        throw "The $($Registration.Kind) Nostr VPN registration survived its uninstaller."
    }
    if (& $ExecutableExists $Registration) {
        throw "The $($Registration.Kind) Nostr VPN executable survived its uninstaller."
    }
}

function Invoke-NvpnInstallerMigration {
    # Resolve and validate every registration before changing any installation.
    # Neither supported installer removes roaming app/config data.
    $registrations = @(Get-NvpnOwnedRegistrations)
    Stop-NvpnGuiProcesses
    foreach ($registration in $registrations | Sort-Object { $_.Kind -eq 'current' }) {
        Invoke-NvpnOwnedUninstall $registration
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-NvpnInstallerMigration
        exit 0
    } catch {
        Write-Error $_
        exit 1
    }
}
