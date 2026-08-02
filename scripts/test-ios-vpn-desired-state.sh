#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-vpn-desired-state.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let suite = "nvpn.vpn-desired-state.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = VpnDesiredStateStore(defaults: defaults)

require(!store.restore(runtimeEnabled: false), "fresh stopped state restored on")
require(defaults.object(forKey: VpnDesiredStateStore.key) == nil, "fresh off became intent")
require(store.permitsAutomaticStart(), "fresh install blocked configured autoconnect")
require(store.restore(runtimeEnabled: true), "running upgrade did not migrate intent")
require(store.restore(runtimeEnabled: false), "transient missing sidecar erased on intent")
store.recordRequest(false)
require(!store.restore(runtimeEnabled: true), "confirmed explicit stop was ignored")
require(!store.permitsAutomaticStart(), "explicit stop allowed autoconnect resurrection")
store.recordRequest(true)
require(store.restore(runtimeEnabled: false), "start request did not survive missing sidecar")
require(store.permitsAutomaticStart(), "explicit start blocked autoconnect restoration")

print("iOS VPN desired-state tests passed")
SWIFT

xcrun swiftc -warnings-as-errors \
  "$ROOT/ios/Sources/VpnDesiredStateStore.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/test-ios-vpn-desired-state"
"$TMP_DIR/test-ios-vpn-desired-state"

python3 - \
  "$ROOT/ios/Sources/PacketTunnelController.swift" \
  "$ROOT/ios/Sources/AppModel.swift" \
  "$ROOT/ios/Sources/AppModelTunnelLifecycle.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
app = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
lifecycle = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
start = source.split("func start(", 1)[1].split("static func routeState", 1)[0]
call = start.index("startVPNTunnel(options: options)")
ready = start.index("try await waitForConnected(manager)")
if ready < call:
    raise SystemExit("PacketTunnel readiness check precedes the start request")
if "NEVPNStatusDidChange" not in source or "NEVPNStatus.connected.rawValue" not in source:
    raise SystemExit("PacketTunnel readiness does not observe an actual connected transition")
start_model = app.split("func start()", 1)[1].split("func handleScenePhase", 1)[0]
if "pendingVpnTransitionEnabled = desiredVpnEnabled" not in start_model:
    raise SystemExit("restored VPN-on intent does not enter the production transition queue")
if "AppStorePolicy.allowsVpnStart" not in start_model:
    raise SystemExit("restored VPN-on intent bypasses App Store startup policy")
suspend = app.split("private func suspendNativeCore()", 1)[1].split(
    "private func resumeNativeCore()", 1
)[0]
if "pendingVpnTransitionEnabled != nil" not in suspend:
    raise SystemExit("backgrounding can discard an unconfirmed explicit VPN-off request")
sync = app.split("func syncPacketTunnelConfig(", 1)[1].split(
    "private func actionRequiresPacketTunnelConfigSync", 1
)[0]
request = app.split("func setVpnEnabled(", 1)[1].split(
    "func schedulePacketTunnelConfigSync", 1
)[0]
start_transition = lifecycle.split("private func performVpnStart(", 1)[1].split(
    "private func performVpnStop", 1
)[0]
record = request.index("recordRequest(enabled)")
if not record < request.index("guard !enabled || core != nil") < request.index(
    "pendingVpnTransitionEnabled = enabled"
) < request.index("enqueuePacketTunnelOperation"):
    raise SystemExit("explicit VPN intent is not durable before fallible asynchronous work")
if "recordRequest(" in sync or "recordRequest(" in start_transition:
    raise SystemExit("VPN intent is duplicated after asynchronous work starts")
stop = lifecycle.split("private func performVpnStop(", 1)[1].split(
    "private func packetTunnelTransitionIsCurrent", 1
)[0]
if "recordRequest(" in stop or "recordConfirmedExplicitStop" in stop:
    raise SystemExit("explicit VPN-off intent is delayed until asynchronous teardown")
for name, body in (
    ("config scheduling", app.split("func schedulePacketTunnelConfigSync", 1)[1].split(
        "func syncPacketTunnelConfig", 1
    )[0]),
    ("config synchronization", sync),
    ("tunnel start", start_transition),
):
    if "vpnStartIsDesired()" not in body:
        raise SystemExit(f"{name} can resurrect a persisted explicit VPN-off request")
autoconnect = app.split("func ensureAutoconnectPacketTunnel", 1)[1].split(
    "static func packetTunnelNeedsStart", 1
)[0]
if "vpnDesiredState.permitsAutomaticStart()" not in autoconnect:
    raise SystemExit("autoconnect ignores persisted explicit VPN-off intent")
controller_start = source.split("func start(", 1)[1].split(
    "static func routeState", 1
)[0]
save = controller_start.index("try await save(")
stop_active = controller_start.index("stopAndWaitForDisconnected(manager)")
if save > stop_active:
    raise SystemExit("route update still stops the live tunnel before preferences are durable")
if "Task {" not in controller_start or ".value" not in controller_start:
    raise SystemExit("route update transaction is not shielded from caller cancellation")
startup_routes = lifecycle.split("private func reconcileStartupTunnelRoutes", 1)[1].split(
    "private func requireStartupTunnelReconciliation", 1
)[0]
if not startup_routes.index("packetTunnelNeedsStart") < startup_routes.index(
    "installedRouteState"
) < startup_routes.index("vpnController.start"):
    raise SystemExit("startup does not restart persisted VPN-on intent after NE disconnect")
if "observedStartingStatus" not in source or "connectionFailed(status)" not in source:
    raise SystemExit("PacketTunnel readiness ignores a terminal failed start")
if "continuation.onTermination" not in source or "group.cancelAll()" not in source:
    raise SystemExit("PacketTunnel readiness observer is not cancellation-safe")
PY
