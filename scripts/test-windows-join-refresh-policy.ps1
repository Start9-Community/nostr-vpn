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
$Flags = [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic
$IntervalMethod = $ViewModelType.GetMethod("RefreshIntervalForState", $Flags)
$CanStartMethod = $ViewModelType.GetMethod("CanStartRefresh", $Flags)
if (!$IntervalMethod -or !$CanStartMethod) {
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

if (!$CanStartMethod.Invoke($null, @($false, $false))) {
  throw "idle Windows refresh was incorrectly blocked"
}
if ($CanStartMethod.Invoke($null, @($true, $false))) {
  throw "Windows refresh overlapped a dispatched action"
}
if ($CanStartMethod.Invoke($null, @($false, $true))) {
  throw "Windows refresh policy permits overlapping native refreshes"
}

Write-Output "WINDOWS_JOIN_REFRESH_POLICY_OK"
