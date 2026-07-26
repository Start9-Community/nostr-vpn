#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-packet-flow-lifecycle.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool? {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }
}

let stoppedBeforeAttach = PacketFlowBridgeLifecycle(generation: 41)
var stoppedAttachCalls = 0
require(stoppedBeforeAttach.stop(), "first stop must be the terminal transition")
require(
    !stoppedBeforeAttach.attach {
        stoppedAttachCalls += 1
        return true
    },
    "attach must not resurrect a bridge stopped before attachment"
)
require(stoppedAttachCalls == 0, "stopped bridge must not transfer callback ownership")
require(!stoppedBeforeAttach.startReading(), "stopped bridge must not start reading")
require(!stoppedBeforeAttach.callbacksAllowed, "stopped bridge must reject callbacks")
require(!stoppedBeforeAttach.stop(), "stop must be idempotent")

let stoppedDuringAttach = PacketFlowBridgeLifecycle(generation: 42)
let attachEntered = DispatchSemaphore(value: 0)
let releaseAttach = DispatchSemaphore(value: 0)
let attachFinished = DispatchSemaphore(value: 0)
let attachResult = LockedResult()
let attachQueue = DispatchQueue(label: "nvpn.packet-flow.lifecycle.attach")
attachQueue.async {
    let attached = stoppedDuringAttach.attach {
        attachEntered.signal()
        releaseAttach.wait()
        return true
    }
    attachResult.set(attached)
    attachFinished.signal()
}
require(
    attachEntered.wait(timeout: .now() + 2) == .success,
    "attach closure did not start"
)
require(
    stoppedDuringAttach.callbacksAllowed,
    "callbacks must remain valid while Rust accepts their retained context"
)
require(stoppedDuringAttach.stop(), "stop during attachment must win irreversibly")
releaseAttach.signal()
require(
    attachFinished.wait(timeout: .now() + 2) == .success,
    "attach closure did not finish"
)
require(
    attachResult.get() == false,
    "successful native attachment must not reactivate a stopped bridge"
)
require(!stoppedDuringAttach.startReading(), "reading resurrected after stop won")
require(!stoppedDuringAttach.callbacksAllowed, "callbacks remained active after stop")

let running = PacketFlowBridgeLifecycle(generation: 43)
var attachCalls = 0
require(
    running.attach {
        attachCalls += 1
        return true
    },
    "ordinary attachment failed"
)
require(attachCalls == 1, "attachment must transfer callback ownership exactly once")
require(running.callbacksAllowed, "attached callbacks must be accepted")
require(running.startReading(), "attached bridge did not enter reading state")
var registrations = 0
require(
    running.registerRead {
        registrations += 1
    },
    "running bridge did not register its read"
)
require(registrations == 1, "read registration must execute exactly once")
require(running.stop(), "running bridge did not stop")
require(
    !running.registerRead {
        registrations += 1
    },
    "read registration ran after stop"
)
require(registrations == 1, "stop allowed a new packet-flow read registration")
require(!running.attach { true }, "stopped bridge attached twice")
require(running.generation == 43, "bridge generation changed")

let rejected = PacketFlowBridgeLifecycle(generation: 44)
require(!rejected.attach { false }, "native attachment rejection was accepted")
require(!rejected.callbacksAllowed, "rejected attachment left callbacks active")
require(!rejected.startReading(), "rejected attachment started reading")

print("iOS PacketFlowBridge lifecycle tests passed")
SWIFT

xcrun swiftc \
  -warnings-as-errors \
  "$ROOT/ios/PacketTunnel/PacketFlowBridgeLifecycle.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/test-ios-packet-flow-lifecycle"
"$TMP_DIR/test-ios-packet-flow-lifecycle"
