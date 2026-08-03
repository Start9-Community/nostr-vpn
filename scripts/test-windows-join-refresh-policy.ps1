#Requires -Version 7

param(
  [Parameter(Mandatory = $true)]
  [string]$AssemblyPath
)

$ErrorActionPreference = "Stop"
if (!(Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
  throw "Windows app assembly is missing: $AssemblyPath"
}

$Assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path $AssemblyPath))
$StateType = $Assembly.GetType("NostrVpn.Windows.Core.NativeAppState", $true)
$ViewModelType = $Assembly.GetType("NostrVpn.Windows.ViewModels.AppViewModel", $true)
$GateType = $Assembly.GetType("NostrVpn.Windows.ViewModels.NativeCoreCallGate", $true)
$Flags = [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic
$IntervalMethod = $ViewModelType.GetMethod("RefreshIntervalForState", $Flags)
$InstanceFlags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
$TryRefreshMethod = $GateType.GetMethod("TryEnterRefresh", $InstanceFlags)
$EnterDispatchMethod = $GateType.GetMethod("EnterDispatchAsync", $InstanceFlags)
if (!$IntervalMethod -or !$TryRefreshMethod -or !$EnterDispatchMethod) {
  throw "Windows join refresh policy methods are missing"
}

$State = [Activator]::CreateInstance($StateType)
$Fast = $IntervalMethod.Invoke($null, @($State, $true))
if ($Fast -ne [TimeSpan]::FromSeconds(1)) {
  throw "active join coordination did not select the bounded fast refresh interval"
}

$Idle = $IntervalMethod.Invoke($null, @($State, $false))
if ($Idle -ne [TimeSpan]::FromSeconds(15)) {
  throw "expired join coordination window did not restore idle refresh"
}

$State.PaidRouteMarket.Wallet.LastAction.Kind = "topup"
$Wallet = $IntervalMethod.Invoke($null, @($State, $false))
if ($Wallet -ne [TimeSpan]::FromSeconds(2)) {
  throw "wallet top-up refresh policy changed"
}

$Gate = [Activator]::CreateInstance($GateType, $true)
$RefreshLease = $TryRefreshMethod.Invoke($Gate, @())
if (!$RefreshLease) {
  throw "idle Windows refresh could not enter the native core gate"
}
$QueuedDispatch = [Threading.Tasks.Task]$EnterDispatchMethod.Invoke($Gate, @())
Start-Sleep -Milliseconds 100
if ($QueuedDispatch.IsCompleted) {
  throw "Windows dispatch overlapped an active native refresh"
}
$RefreshLease.Dispose()
if (!$QueuedDispatch.Wait(2000)) {
  throw "Windows dispatch was dropped instead of waiting for refresh"
}
$DispatchLease = $QueuedDispatch.GetType().GetProperty("Result").GetValue($QueuedDispatch)
$BlockedRefresh = $TryRefreshMethod.Invoke($Gate, @())
if ($BlockedRefresh) {
  $BlockedRefresh.Dispose()
  throw "Windows refresh overlapped an active native dispatch"
}
$DispatchLease.Dispose()
$NextRefresh = $TryRefreshMethod.Invoke($Gate, @())
if (!$NextRefresh) {
  throw "Windows native core gate did not release after dispatch"
}
$NextRefresh.Dispose()

Write-Output "WINDOWS_NATIVE_CORE_CALL_GATE_OK"
Write-Output "WINDOWS_JOIN_REFRESH_POLICY_OK"
