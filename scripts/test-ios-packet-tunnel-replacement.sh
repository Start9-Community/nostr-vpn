#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-packet-replacement.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

enum FixtureError: Error { case injected }
enum FailurePoint { case saveOrReload, stopOnce, stopAlways, startOrWait, none }

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

actor Injection {
    let point: FailurePoint
    private(set) var disconnectCalls = 0

    init(_ point: FailurePoint) { self.point = point }

    func saveAndReload(marker: PacketTunnelReplacementStateStore) throws {
        require(marker.restartRequired(), "preferences save preceded restart marker")
        if point == .saveOrReload { throw FixtureError.injected }
    }

    func disconnect() throws {
        disconnectCalls += 1
        if point == .stopAlways || (point == .stopOnce && disconnectCalls == 1) {
            throw FixtureError.injected
        }
    }

    func startAndWait() throws {
        if point == .startOrWait { throw FixtureError.injected }
    }
}

func expectFailure(
    _ point: FailurePoint,
    disconnectConfirmed: Bool,
    disconnectCalls: Int,
    state: PacketTunnelReplacementStateStore,
    transaction: PacketTunnelReplacementTransaction
) async {
    let injection = Injection(point)
    do {
        try await transaction.perform(
            replacingActiveTunnel: true,
            saveAndReload: { try await injection.saveAndReload(marker: state) },
            disconnect: { try await injection.disconnect() },
            startAndWait: { try await injection.startAndWait() }
        )
        fatalError("injected \(point) failure passed")
    } catch let error as PacketTunnelReplacementError {
        require(
            error.disconnectConfirmed == disconnectConfirmed,
            "injected \(point) reported the wrong disconnect state"
        )
    } catch {
        fatalError("injected \(point) escaped without replacement context: \(error)")
    }
    require(state.restartRequired(), "failed replacement cleared restart marker")
    let observedCalls = await injection.disconnectCalls
    require(observedCalls == disconnectCalls, "injected \(point) cleanup count was wrong")
}

@main
struct PacketTunnelReplacementTests {
    static func main() async {
        let markerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nvpn.packet-replacement.\(UUID().uuidString)")
            .appendingPathComponent(PacketTunnelReplacementStateStore.markerFileName)
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }
        let state = PacketTunnelReplacementStateStore(markerURL: markerURL)
        let transaction = PacketTunnelReplacementTransaction(state: state)
        require(!state.restartRequired(), "fresh state requires a restart")

        for (point, confirmed, calls) in [
            (FailurePoint.saveOrReload, true, 1),
            (.stopOnce, true, 2),
            (.stopAlways, false, 2),
            (.startOrWait, true, 2),
        ] {
            await expectFailure(
                point, disconnectConfirmed: confirmed, disconnectCalls: calls,
                state: state, transaction: transaction
            )
        }

        let relaunchedState = PacketTunnelReplacementStateStore(markerURL: markerURL)
        require(relaunchedState.restartRequired(), "process-death marker was not durable")
        let success = Injection(.none)
        try! await transaction.perform(
            replacingActiveTunnel: true,
            saveAndReload: { try await success.saveAndReload(marker: state) },
            disconnect: { try await success.disconnect() },
            startAndWait: { try await success.startAndWait() }
        )
        require(!state.restartRequired(), "confirmed replacement retained marker")
        print("iOS packet-tunnel replacement tests passed")
    }
}
SWIFT

xcrun swiftc -warnings-as-errors -parse-as-library \
  "$ROOT/ios/Sources/PacketTunnelReplacementTransaction.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/test-ios-packet-tunnel-replacement"
"$TMP_DIR/test-ios-packet-tunnel-replacement"

python3 - \
  "$ROOT/ios/Sources/PacketTunnelController.swift" \
  "$ROOT/ios/Sources/AppModelTunnelLifecycle.swift" <<'PY'
import pathlib
import sys

controller = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
lifecycle = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
start = controller.split("private func updateAndStart(", 1)[1].split(
    "static func routeState", 1
)[0]
for token in (
    "PacketTunnelReplacementTransaction",
    "replacingActiveTunnel: hadActiveTunnel",
    "saveAndReload:",
    "disconnect:",
    "startAndWait:",
):
    if token not in start:
        raise SystemExit(f"production replacement transaction is missing {token}")
startup = lifecycle.split("private func reconcileStartupTunnelRoutes", 1)[1].split(
    "private func requireStartupTunnelReconciliation", 1
)[0]
marker = startup.index("replacementRestartRequired()")
route_parse = startup.index("PacketTunnelController.routeState")
if marker > route_parse or "if !needsStart, !replacementRestartRequired" not in startup:
    raise SystemExit("startup trusts preferences after an incomplete replacement")
enqueue = lifecycle.split("func enqueuePacketTunnelOperation", 1)[1].split(
    "private func performVpnStart", 1
)[0]
failure = enqueue.split("} catch {", 1)[1]
if "PacketTunnelReplacementError" not in failure or "disconnectConfirmed" not in failure:
    raise SystemExit("app state can claim VPN-off without confirmed replacement cleanup")
PY
