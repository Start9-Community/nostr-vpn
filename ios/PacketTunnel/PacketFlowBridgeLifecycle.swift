import Foundation

/// The irreversible lifecycle shared by the production packet-flow bridge and
/// its deterministic host-side race tests.
final class PacketFlowBridgeLifecycle {
    private enum State {
        case idle
        case attaching
        case attached
        case reading
        case stopped
    }

    let generation: UInt64

    private let lock = NSLock()
    private var state = State.idle

    init(generation: UInt64) {
        self.generation = generation
    }

    /// Runs the native ownership transfer at most once. The operation runs
    /// outside the lock because Rust may invoke a callback before it returns.
    /// A concurrent stop always wins over a successful native attachment.
    func attach(_ operation: () -> Bool) -> Bool {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return false
        }
        state = .attaching
        lock.unlock()

        let attached = operation()

        lock.lock()
        defer { lock.unlock() }
        guard state == .attaching else {
            return false
        }
        state = attached ? .attached : .stopped
        return attached
    }

    /// Moves an attached bridge into its read-loop state without ever
    /// reactivating a stopped bridge.
    func startReading() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .attached else {
            return false
        }
        state = .reading
        return true
    }

    /// Registers one `NEPacketTunnelFlow.readPackets` operation while stop is
    /// excluded by the same lock. The API only registers an asynchronous
    /// completion and returns immediately.
    func registerRead(_ operation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .reading else {
            return false
        }
        operation()
        return true
    }

    var isReading: Bool {
        lock.lock()
        let result = state == .reading
        lock.unlock()
        return result
    }

    var callbacksAllowed: Bool {
        lock.lock()
        let result = state == .attaching || state == .attached || state == .reading
        lock.unlock()
        return result
    }

    /// Stop is terminal and idempotent. The return value lets failure
    /// callbacks notify the provider only for the first transition.
    @discardableResult
    func stop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != .stopped else {
            return false
        }
        state = .stopped
        return true
    }
}
