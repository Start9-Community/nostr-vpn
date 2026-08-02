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
require(store.restore(runtimeEnabled: true), "running upgrade did not migrate intent")
require(store.restore(runtimeEnabled: false), "transient missing sidecar erased on intent")
store.recordConfirmedExplicitStop()
require(!store.restore(runtimeEnabled: true), "confirmed explicit stop was ignored")
store.recordStartRequest()
require(store.restore(runtimeEnabled: false), "start request did not survive missing sidecar")

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
record = request.index("recordStartRequest()")
if not request.index("guard core != nil") < record < request.index(
    "pendingVpnTransitionEnabled = enabled"
) < request.index("enqueuePacketTunnelOperation"):
    raise SystemExit("VPN-on intent is not durable before the asynchronous transition")
if "recordStartRequest()" in sync or "recordStartRequest()" in start_transition:
    raise SystemExit("VPN-on intent is duplicated after asynchronous work starts")
stop = lifecycle.split("private func performVpnStop(", 1)[1].split(
    "private func packetTunnelTransitionIsCurrent", 1
)[0]
confirmed = stop.index("stopAndWaitForDisconnected()")
clear = stop.index("recordConfirmedExplicitStop()")
native_off = stop.index("NativeActions.disconnectVpn()")
if not confirmed < clear < native_off:
    raise SystemExit("VPN-on intent is cleared before an explicit stop is confirmed")
if "observedStartingStatus" not in source or "connectionFailed(status)" not in source:
    raise SystemExit("PacketTunnel readiness ignores a terminal failed start")
if "continuation.onTermination" not in source or "group.cancelAll()" not in source:
    raise SystemExit("PacketTunnel readiness observer is not cancellation-safe")
PY
