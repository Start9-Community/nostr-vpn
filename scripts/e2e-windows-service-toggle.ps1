param(
  [string]$AppExe,
  [string]$ArtifactRoot
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
if (!$ArtifactRoot) {
  $ArtifactRoot = Join-Path $Root "artifacts\windows-service-toggle"
}
if (!$AppExe) {
  $AppExe = Join-Path $Root "windows\NostrVpn.Windows\bin\Debug\net8.0-windows\NostrVpn.Windows.exe"
}
$DataDir = Join-Path $ArtifactRoot "app-data"
$FixtureResult = Join-Path $ArtifactRoot "fixture.json"
$Process = $null
$ElevationProcess = $null

Set-Location $Root

if (Get-Service NvpnService -ErrorAction SilentlyContinue) {
  throw "Windows service-toggle E2E requires nvpn to be absent so it cannot disturb an installed service"
}

New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $DataDir
Remove-Item -Force -ErrorAction SilentlyContinue $FixtureResult

& cargo build -q -p nostr-vpn-app-core --example desktop_roster_e2e_fixture
if ($LASTEXITCODE -ne 0) {
  throw "desktop roster fixture build failed"
}
$CargoTarget = (& cargo metadata --no-deps --format-version 1 | ConvertFrom-Json).target_directory
$Fixture = Join-Path $CargoTarget "debug\examples\desktop_roster_e2e_fixture.exe"
& $Fixture prepare --data-dir $DataDir --result $FixtureResult
if ($LASTEXITCODE -ne 0) {
  throw "desktop roster fixture preparation failed"
}
if (!(Test-Path $AppExe)) {
  throw "Windows app executable not found: $AppExe"
}

Get-Process -Name NostrVpn.Windows -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
$env:NVPN_APP_DATA_DIR = $DataDir
$Dotnet = Get-Command dotnet -ErrorAction Stop
$env:DOTNET_ROOT = Split-Path -Parent $Dotnet.Source
$Process = Start-Process -FilePath $AppExe -PassThru

try {
  $WindowDeadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $WindowDeadline) {
    Start-Sleep -Milliseconds 200
    $Process.Refresh()
    if ($Process.HasExited) {
      throw "Windows app exited before the VPN toggle could be invoked"
    }
    if ($Process.MainWindowHandle -ne 0) {
      break
    }
  }
  if ($Process.MainWindowHandle -eq 0) {
    throw "Windows app did not create its main window"
  }

  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NvpnServiceToggleInput {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr handle, out Rect rect);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr handle);
  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint flags);
}
'@
  if ([NvpnServiceToggleInput]::SetThreadExecutionState(2147483651) -eq 0) {
    throw "could not hold the interactive display for visible UI evidence"
  }
  $Process.WaitForInputIdle(10000) | Out-Null
  Start-Sleep -Milliseconds 750
  $WindowRect = [NvpnServiceToggleInput+Rect]::new()
  if (![NvpnServiceToggleInput]::GetWindowRect($Process.MainWindowHandle, [ref]$WindowRect)) {
    throw "could not read the real WPF window geometry"
  }
  Write-Host (
    "WPF window rect: left={0} top={1} right={2} bottom={3}" -f
    $WindowRect.Left,
    $WindowRect.Top,
    $WindowRect.Right,
    $WindowRect.Bottom
  )
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $Window = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
  $ButtonCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button
  )
  $Buttons = $Window.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    $ButtonCondition
  )
  $Toggle = $null
  foreach ($Button in $Buttons) {
    if ($Button.Current.Name -eq "Off") {
      $Toggle = $Button
      break
    }
  }
  if (!$Toggle) {
    $ButtonNames = @($Buttons | ForEach-Object { $_.Current.Name }) -join ", "
    throw "Windows VPN toggle button was not found after input idle; buttons: $ButtonNames"
  }
  [NvpnServiceToggleInput]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
  Start-Sleep -Milliseconds 250
  Add-Type -AssemblyName System.Drawing
  $ScreenshotCaptured = $false
  $ScreenshotError = $null
  for ($ScreenshotAttempt = 1; $ScreenshotAttempt -le 20; $ScreenshotAttempt++) {
    $Screenshot = [System.Drawing.Bitmap]::new(
      $WindowRect.Right - $WindowRect.Left,
      $WindowRect.Bottom - $WindowRect.Top
    )
    $ScreenshotGraphics = [System.Drawing.Graphics]::FromImage($Screenshot)
    try {
      $ScreenshotGraphics.CopyFromScreen(
        $WindowRect.Left,
        $WindowRect.Top,
        0,
        0,
        $Screenshot.Size
      )
      $PaintSample = $Screenshot.GetPixel(
        [Math]::Min(50, $Screenshot.Width - 1),
        [Math]::Min(100, $Screenshot.Height - 1)
      )
      if (
        $PaintSample.R -ge 250 -and
        $PaintSample.G -ge 250 -and
        $PaintSample.B -ge 250
      ) {
        throw "the visible WPF content has not painted yet"
      }
      $Screenshot.Save((Join-Path $ArtifactRoot "window.png"))
      $ScreenshotCaptured = $true
      break
    } catch {
      $ScreenshotError = $_
      if ($ScreenshotAttempt -lt 20) {
        Start-Sleep -Milliseconds 250
      }
    } finally {
      $ScreenshotGraphics.Dispose()
      $Screenshot.Dispose()
    }
  }
  if (!$ScreenshotCaptured) {
    throw "could not capture the painted visible WPF window after 20 attempts: $ScreenshotError"
  }
  $Invoke = $Toggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $Invoke.Invoke()

  $PromptDeadline = (Get-Date).AddSeconds(20)
  $ConsentObserved = $false
  while ((Get-Date) -lt $PromptDeadline) {
    Start-Sleep -Milliseconds 100
    $ElevationProcess = Get-CimInstance Win32_Process |
      Where-Object {
        $_.ParentProcessId -eq $Process.Id -and
        $_.Name -ieq "powershell.exe"
      } |
      Select-Object -First 1
    if ($ElevationProcess -and (Get-Process consent -ErrorAction SilentlyContinue)) {
      $ConsentObserved = $true
      break
    }
  }
  if (!$ConsentObserved) {
    throw "VPN toggle did not open a Windows UAC consent prompt"
  }

  # Cancelling the unelevated PowerShell requester closes the secure-desktop
  # request without approving or installing anything. The elevated outer
  # driver owns consent.exe cleanup because the intentionally limited GUI task
  # cannot terminate the secure-desktop process itself.
  Stop-Process -Id $ElevationProcess.ProcessId -Force -ErrorAction Stop
  if (Get-Service NvpnService -ErrorAction SilentlyContinue) {
    throw "service-toggle prompt test unexpectedly installed the nvpn service"
  }

  Write-Host "WINDOWS_SERVICE_TOGGLE_UAC_PROMPT_OK"
} finally {
  try {
    [NvpnServiceToggleInput]::SetThreadExecutionState(2147483648) | Out-Null
  } catch {
  }
  if ($ElevationProcess) {
    Stop-Process -Id $ElevationProcess.ProcessId -Force -ErrorAction SilentlyContinue
  }
  if ($Process -and !$Process.HasExited) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  }
}
