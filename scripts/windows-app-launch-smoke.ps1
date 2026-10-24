param(
  [Parameter(Mandatory = $true)]
  [string]$AppExe,
  [string]$ArtifactRoot,
  [int]$StartupTimeoutSeconds = 30,
  [int]$AliveSeconds = 5,
  [double]$IdleCpuMaxPercent = -1,
  [double]$IdleCpuSampleSeconds = -1,
  [double]$IdleCpuSettleSeconds = -1,
  [switch]$NoWindowRequired,
  [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
if (!$ArtifactRoot) {
  $ArtifactRoot = Join-Path $Root "artifacts"
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
$ResultPath = Join-Path $ArtifactRoot "windows-app-launch-smoke.json"
$EventsPath = Join-Path $ArtifactRoot "windows-app-launch-events.json"
$IdleCpuResultPath = Join-Path $ArtifactRoot "windows-app-idle-cpu.json"

function Test-NvpnTruthy {
  param([string]$Value)
  return $Value -match '^(1|true|yes|on)$'
}

function Test-NvpnFalsey {
  param([string]$Value)
  return $Value -match '^(0|false|no|off)$'
}

function Get-NvpnNumberSetting {
  param(
    [double]$Explicit,
    [string]$PlatformEnvName,
    [string]$SharedEnvName,
    [double]$Default
  )
  if ($Explicit -ge 0) {
    return $Explicit
  }
  $platformValue = [Environment]::GetEnvironmentVariable($PlatformEnvName)
  if (![string]::IsNullOrWhiteSpace($platformValue)) {
    return [double]::Parse($platformValue, [Globalization.CultureInfo]::InvariantCulture)
  }
  $sharedValue = [Environment]::GetEnvironmentVariable($SharedEnvName)
  if (![string]::IsNullOrWhiteSpace($sharedValue)) {
    return [double]::Parse($sharedValue, [Globalization.CultureInfo]::InvariantCulture)
  }
  return $Default
}

$IdleCpuGateValue = [Environment]::GetEnvironmentVariable("NVPN_WINDOWS_APP_IDLE_CPU_GATE")
if ([string]::IsNullOrWhiteSpace($IdleCpuGateValue)) {
  $IdleCpuGateValue = [Environment]::GetEnvironmentVariable("NVPN_IDLE_CPU_GATE")
}
if ([string]::IsNullOrWhiteSpace($IdleCpuGateValue)) {
  $IdleCpuGateValue = "1"
}
$IdleCpuGateEnabled = !(Test-NvpnFalsey $IdleCpuGateValue)
$IdleCpuMaxPercent = Get-NvpnNumberSetting $IdleCpuMaxPercent "NVPN_WINDOWS_APP_IDLE_CPU_MAX_PERCENT" "NVPN_IDLE_CPU_MAX_PERCENT" 5
$IdleCpuSampleSeconds = Get-NvpnNumberSetting $IdleCpuSampleSeconds "NVPN_WINDOWS_APP_IDLE_CPU_SAMPLE_SECONDS" "NVPN_IDLE_CPU_SAMPLE_SECONDS" 60
$IdleCpuSettleSeconds = Get-NvpnNumberSetting $IdleCpuSettleSeconds "NVPN_WINDOWS_APP_IDLE_CPU_SETTLE_SECONDS" "NVPN_IDLE_CPU_SETTLE_SECONDS" 20

function Stop-NostrVpnWindows {
  Get-Process -Name NostrVpn.Windows -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-NostrVpnEvents {
  param([datetime]$Since)

  try {
    Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $Since } -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ProviderName -in @(".NET Runtime", "Application Error", "Windows Error Reporting") -or
        $_.Message -match "NostrVpn\.Windows"
      } |
      Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message
  } catch {
    @([pscustomobject]@{
        TimeCreated      = Get-Date
        ProviderName     = "windows-app-launch-smoke"
        Id               = 0
        LevelDisplayName = "Warning"
        Message          = "Could not read Windows Application event log: $($_.Exception.Message)"
      })
  }
}

function Write-SmokeResult {
  param(
    [bool]$Ok,
    [string]$ErrorMessage = "",
    [int]$ProcessId = 0,
    [int]$ExitCode = 0,
    [bool]$WindowSeen = $false,
    [Nullable[double]]$IdleCpuPercent = $null,
    [string]$IdleCpuResult = ""
  )

  New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
  [pscustomobject]@{
    ok                = $Ok
    appExe            = $AppExe
    processId         = $ProcessId
    exitCode          = $ExitCode
    windowSeen        = $WindowSeen
    idleCpuPercent    = $IdleCpuPercent
    idleCpuMaxPercent = $IdleCpuMaxPercent
    idleCpuResult     = $IdleCpuResult
    error             = $ErrorMessage
    generatedAt       = (Get-Date).ToUniversalTime().ToString("o")
  } | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $ResultPath
}

function Start-NvpnSleepSeconds {
  param([double]$Seconds)
  if ($Seconds -le 0) {
    return
  }
  Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Round($Seconds * 1000)))
}

function Invoke-IdleCpuGate {
  param([System.Diagnostics.Process]$Process)
  if (!$IdleCpuGateEnabled) {
    Write-Host "Skipping Windows app idle CPU gate because NVPN_WINDOWS_APP_IDLE_CPU_GATE=$IdleCpuGateValue"
    return $null
  }
  if ($IdleCpuSampleSeconds -le 0) {
    throw "IdleCpuSampleSeconds must be positive"
  }
  if ($IdleCpuSettleSeconds -lt 0) {
    throw "IdleCpuSettleSeconds must be non-negative"
  }

  Start-NvpnSleepSeconds $IdleCpuSettleSeconds
  $Process.Refresh()
  if ($Process.HasExited) {
    throw "NostrVpn.Windows exited before idle CPU sampling"
  }
  $startCpu = $Process.TotalProcessorTime.TotalSeconds
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  Start-NvpnSleepSeconds $IdleCpuSampleSeconds
  $watch.Stop()
  $Process.Refresh()
  if ($Process.HasExited) {
    throw "NostrVpn.Windows exited during idle CPU sampling"
  }
  $endCpu = $Process.TotalProcessorTime.TotalSeconds
  $elapsed = [Math]::Max($watch.Elapsed.TotalSeconds, 0.001)
  $cpuPercent = [Math]::Max(0.0, $endCpu - $startCpu) * 100.0 / $elapsed
  $ok = $cpuPercent -le $IdleCpuMaxPercent
  $threads = @($Process.Threads |
      Sort-Object TotalProcessorTime -Descending |
      Select-Object -First 8 |
      ForEach-Object {
        [pscustomobject]@{
          id                   = $_.Id
          cpuSeconds           = $_.TotalProcessorTime.TotalSeconds
          userCpuSeconds       = $_.UserProcessorTime.TotalSeconds
          privilegedCpuSeconds = $_.PrivilegedProcessorTime.TotalSeconds
          state                = [string]$_.ThreadState
        }
      })
  $result = [pscustomobject]@{
    ok             = $ok
    mode           = "windows-process"
    label          = "Windows app"
    pids           = @($Process.Id)
    cpuPercent     = $cpuPercent
    maxPercent     = $IdleCpuMaxPercent
    sampleSeconds  = $IdleCpuSampleSeconds
    settleSeconds  = $IdleCpuSettleSeconds
    elapsedSeconds = $elapsed
    threads        = $threads
    generatedAt    = (Get-Date).ToUniversalTime().ToString("o")
  }
  New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
  $result | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $IdleCpuResultPath
  if (!$ok) {
    $result | ConvertTo-Json -Depth 4 | Write-Host
    throw ("Windows app idle CPU gate failed: {0:N3}% > {1:N3}%. Result: {2}" -f $cpuPercent, $IdleCpuMaxPercent, $IdleCpuResultPath)
  }
  Write-Host ("Windows app idle CPU ok: {0:N3}% <= {1:N3}%" -f $cpuPercent, $IdleCpuMaxPercent)
  Write-Host "Result: $IdleCpuResultPath"
  return $cpuPercent
}

if (!(Test-Path $AppExe)) {
  throw "Windows app executable not found: $AppExe"
}

New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
Stop-NostrVpnWindows

$startTime = (Get-Date).AddSeconds(-3)
$proc = $null
$windowSeen = $false

try {
  $startProcess = @{
    FilePath = $AppExe
    WorkingDirectory = (Split-Path -Parent $AppExe)
    PassThru = $true
  }
  if ($NoWindowRequired) {
    # SSH runs this smoke in Windows session 0, where a "visible" WPF window is
    # software-rendered without an interactive desktop and consumes a steady
    # render-thread core slice. Test the app's real tray-idle state instead.
    $startProcess.ArgumentList = @("--hidden")
  }
  $proc = Start-Process @startProcess
  $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)

  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) {
      $events = @(Get-NostrVpnEvents -Since $startTime)
      $events | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 $EventsPath
      Write-SmokeResult -Ok $false -ErrorMessage "NostrVpn.Windows exited during startup" -ProcessId $proc.Id -ExitCode $proc.ExitCode -WindowSeen $windowSeen
      $eventText = if ($events.Count -gt 0) { ($events | Select-Object -First 3 | ForEach-Object { $_.Message }) -join "`n---`n" } else { "No matching Application event-log entries were found." }
      throw "NostrVpn.Windows exited during startup with code $($proc.ExitCode). Recent event log:`n$eventText"
    }

    if ($NoWindowRequired -or $proc.MainWindowHandle -ne 0) {
      $windowSeen = $proc.MainWindowHandle -ne 0
      break
    }
  }

  if (!$NoWindowRequired -and !$windowSeen) {
    $events = @(Get-NostrVpnEvents -Since $startTime)
    $events | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 $EventsPath
    Write-SmokeResult -Ok $false -ErrorMessage "NostrVpn.Windows stayed alive but did not create a main window" -ProcessId $proc.Id -ExitCode 0 -WindowSeen $false
    throw "NostrVpn.Windows stayed alive but did not create a main window within $StartupTimeoutSeconds seconds."
  }

  $aliveUntil = (Get-Date).AddSeconds($AliveSeconds)
  while ((Get-Date) -lt $aliveUntil) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) {
      $events = @(Get-NostrVpnEvents -Since $startTime)
      $events | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 $EventsPath
      Write-SmokeResult -Ok $false -ErrorMessage "NostrVpn.Windows exited after launch" -ProcessId $proc.Id -ExitCode $proc.ExitCode -WindowSeen $windowSeen
      $eventText = if ($events.Count -gt 0) { ($events | Select-Object -First 3 | ForEach-Object { $_.Message }) -join "`n---`n" } else { "No matching Application event-log entries were found." }
      throw "NostrVpn.Windows exited after launch with code $($proc.ExitCode). Recent event log:`n$eventText"
    }
  }

  $idleCpuPercent = Invoke-IdleCpuGate -Process $proc
  $idleCpuResult = if ($IdleCpuGateEnabled) { $IdleCpuResultPath } else { "" }
  Write-SmokeResult -Ok $true -ProcessId $proc.Id -WindowSeen $windowSeen -IdleCpuPercent $idleCpuPercent -IdleCpuResult $idleCpuResult
  Write-Host "WINDOWS_APP_LAUNCH_SMOKE_OK"
  Write-Host "Result: $ResultPath"
} finally {
  if (!$SkipCleanup -and $proc -and !$proc.HasExited) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  }
}
