import Foundation
import NetworkExtension

private actor ProviderSnapshotGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum PacketTunnelControllerError: LocalizedError {
    case managerUnavailable
    case preferencesTimedOut(String)
    case providerMessageTimedOut(String)
    case disconnectTimedOut(Int)

    var errorDescription: String? {
        switch self {
        case .managerUnavailable:
            return "VPN manager unavailable"
        case .preferencesTimedOut(let operation):
            return "\(operation) VPN preferences timed out; approve any iOS VPN configuration prompt and retry"
        case .providerMessageTimedOut(let message):
            return "\(message) packet-tunnel response timed out"
        case .disconnectTimedOut(let status):
            return "VPN disconnect timed out with status \(status); refusing to start a replacement tunnel"
        }
    }
}

struct PacketTunnelRouteState: Equatable {
    let hasDefaultRoute: Bool
    let hasWireGuardExit: Bool
}

final class PacketTunnelController {
    private static let preferencesOperationTimeoutSeconds: TimeInterval = 10
    private static let providerMessageTimeoutSeconds: TimeInterval = 1
    private let runtimeStateGate = ProviderSnapshotGate()
    private let providerBundleIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "NVPNPacketTunnelBundleIdentifier"
    ) as? String ?? "fi.siriusbusiness.nvpn.PacketTunnel"
    private var activeManager: NETunnelProviderManager?

    func start(
        state: AppState,
        network: NetworkState?,
        tunnelConfigJson: String,
        providerOptionsConfigJson: String
    ) async throws {
        try Task.checkCancellation()
        debugLog("PacketTunnelController.start begin")
        let manager = try await loadOrCreateManager()
        try Task.checkCancellation()
        activeManager = manager
        switch manager.connection.status {
        case .invalid, .disconnected:
            break
        case .disconnecting:
            let status = try await waitForDisconnected(manager)
            debugLog("start confirmed prior disconnect status=\(status)")
        default:
            debugLog(
                "stopping active tunnel before preferences update status=\(manager.connection.status.rawValue)"
            )
            manager.connection.stopVPNTunnel()
            let status = try await waitForDisconnected(manager)
            debugLog("start confirmed active tunnel stopped status=\(status)")
        }
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = network?.displayName ?? "Nostr VPN"
        proto.providerConfiguration = [
            "networkName": network?.displayName ?? "Nostr VPN",
            "tunnelIp": state.tunnelIp.isEmpty ? "10.44.0.1/32" : state.tunnelIp,
            "mtu": 1150,
            "mobileTunnelConfigJson": tunnelConfigJson,
        ]
        // Tell iOS to actually use the includedRoutes we install
        // (without this iOS sometimes lets system services bypass the
        // tunnel, which is also the only condition under which the
        // VPN status badge stays hidden).
        proto.enforceRoutes = true
        if #available(iOS 14.0, *) {
            proto.includeAllNetworks = Self.hasDefaultRoute(in: providerOptionsConfigJson)
        }
        // Don't tear the tunnel down when the screen locks — for a
        // utility VPN we want it to keep running.
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Nostr VPN"
        manager.isEnabled = true
        try Task.checkCancellation()
        debugLog("saving preferences")
        try await save(manager)
        try Task.checkCancellation()
        debugLog("reloading preferences")
        try await reload(manager)
        try Task.checkCancellation()
        debugLog("calling startVPNTunnel status=\(manager.connection.status.rawValue)")
        // Keep providerConfiguration redacted in VPN preferences; the full
        // config is delivered only to this start attempt.
        let options: [String: NSObject] = [
            "mobileTunnelConfigJson": providerOptionsConfigJson as NSString,
        ]
        try Task.checkCancellation()
        try manager.connection.startVPNTunnel(options: options)
        debugLog("startVPNTunnel returned status=\(manager.connection.status.rawValue)")
    }

    private static func hasDefaultRoute(in configJson: String) -> Bool {
        routeState(in: configJson)?.hasDefaultRoute == true
    }

    static func routeState(in configJson: String) -> PacketTunnelRouteState? {
        guard let data = configJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let tunnel = object["tunnel"] as? [String: Any] ?? object
        guard let routes = tunnel["routeTargets"] as? [String] else {
            return nil
        }
        return PacketTunnelRouteState(
            hasDefaultRoute: routes.contains("0.0.0.0/0"),
            hasWireGuardExit: tunnel["wireguardExit"] is [String: Any]
        )
    }

    func stopAndWaitForDisconnected() async throws -> Int {
        try Task.checkCancellation()
        debugLog("PacketTunnelController.stopAndWaitForDisconnected begin")
        guard let manager = try await loadExistingManager() else {
            debugLog("confirmed disconnected: no existing manager")
            return NEVPNStatus.invalid.rawValue
        }
        try Task.checkCancellation()
        activeManager = manager
        manager.connection.stopVPNTunnel()
        return try await waitForDisconnected(manager)
    }

    private func waitForDisconnected(_ manager: NETunnelProviderManager) async throws -> Int {
        var status = manager.connection.status.rawValue
        for _ in 0..<20 {
            if status <= NEVPNStatus.disconnected.rawValue {
                debugLog("confirmed disconnected status=\(status)")
                return status
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            status = manager.connection.status.rawValue
        }
        debugLog("disconnect confirmation timed out status=\(status)")
        throw PacketTunnelControllerError.disconnectTimedOut(status)
    }

    func statusRawValue() async -> Int? {
        do {
            guard let manager = try await loadExistingManager() else {
                return nil
            }
            return manager.connection.status.rawValue
        } catch {
            debugLog("status failed: \(String(describing: error))")
            return nil
        }
    }

    func installedRouteState() async -> PacketTunnelRouteState? {
        do {
            guard let manager = try await loadExistingManager(),
                  let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  let configJson = proto.providerConfiguration?["mobileTunnelConfigJson"] as? String
            else {
                return nil
            }
            return Self.routeState(in: configJson)
        } catch {
            debugLog("installed route state failed: \(String(describing: error))")
            return nil
        }
    }

    func runtimeStateJson() async -> String? {
        await runtimeStateGate.acquire()
        let result = await readRuntimeStateJson()
        await runtimeStateGate.release()
        return result
    }

    private func readRuntimeStateJson() async -> String? {
        guard let sizeData = await providerMessageData("runtimeStateBegin"),
              let sizeText = String(data: sizeData, encoding: .utf8),
              let expectedSize = Int(sizeText),
              expectedSize >= 0,
              expectedSize <= 1_048_576
        else {
            return nil
        }
        var response = Data()
        response.reserveCapacity(expectedSize)
        while response.count < expectedSize {
            guard let chunk = await providerMessageData("runtimeStateChunk:\(response.count)"),
                  !chunk.isEmpty
            else {
                return nil
            }
            response.append(chunk)
        }
        guard response.count == expectedSize else {
            return nil
        }
        return String(data: response, encoding: .utf8)
    }

    func takeAppConfigToml() async -> String? {
        await readAppConfigToml()
    }

    private func readAppConfigToml() async -> String? {
        guard let sizeData = await providerMessageData("appConfigBegin"),
              let sizeText = String(data: sizeData, encoding: .utf8),
              let expectedSize = Int(sizeText),
              expectedSize >= 0,
              expectedSize <= 4_194_304
        else {
            return nil
        }
        var response = Data()
        response.reserveCapacity(expectedSize)
        while response.count < expectedSize {
            guard let chunk = await providerMessageData("appConfigChunk:\(response.count)"),
                  !chunk.isEmpty
            else {
                return nil
            }
            response.append(chunk)
        }
        guard response.count == expectedSize else {
            return nil
        }
        return String(data: response, encoding: .utf8)
    }

    func acknowledgeAppConfigToml() async -> Bool {
        guard let response = await providerMessage("appConfigCommit") else {
            return false
        }
        return response == "ok" || response == "stale"
    }

    private func providerMessage(_ message: String) async -> String? {
        guard let response = await providerMessageData(message) else {
            return nil
        }
        return String(data: response, encoding: .utf8)
    }

    private func providerMessageData(_ message: String) async -> Data? {
        do {
            guard let manager = try await loadExistingManager() else {
                debugLog("providerMessage \(message) skipped: no existing manager")
                return nil
            }
            guard manager.connection.status == .connected else {
                debugLog("providerMessage \(message) skipped status=\(manager.connection.status.rawValue)")
                return nil
            }
            guard let session = manager.connection as? NETunnelProviderSession else {
                return nil
            }
            let data = message.data(using: .utf8) ?? Data()
            return try await withCheckedThrowingContinuation { continuation in
                let completion = ProviderMessageCompletion(continuation)
                do {
                    try session.sendProviderMessage(data) { response in
                        _ = completion.resume(returning: response)
                    }
                } catch {
                    _ = completion.resume(throwing: error)
                }
                let timeoutSeconds = Self.providerMessageTimeoutSeconds
                Task.detached(priority: .utility) {
                    try? await Task.sleep(
                        nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                    )
                    _ = completion.resume(
                        throwing: PacketTunnelControllerError.providerMessageTimedOut(message)
                    )
                }
            }
        } catch {
            debugLog("providerMessage \(message) failed: \(String(describing: error))")
            return nil
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let existing = try await loadExistingManager() {
            debugLog("using existing manager status=\(existing.connection.status.rawValue)")
            return existing
        }
        debugLog("creating new manager")
        return NETunnelProviderManager()
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await loadAllManagers()
        debugLog("loaded managers count=\(managers.count)")
        let matching = managers.filter { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == providerBundleIdentifier
        }
        return matching.first(where: { manager in
            switch manager.connection.status {
            case .invalid, .disconnected:
                return false
            default:
                return true
            }
        }) ?? matching.first
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            let completion = PreferenceManagerLoadCompletion(continuation)
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    _ = completion.resume(throwing: error)
                } else {
                    _ = completion.resume(returning: managers ?? [])
                }
            }
            let timeoutSeconds = Self.preferencesOperationTimeoutSeconds
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                _ = completion.resume(
                    throwing: PacketTunnelControllerError.preferencesTimedOut("load")
                )
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withPreferencesTimeout(operation: "save") { finish in
            manager.saveToPreferences { error in
                finish(error)
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withPreferencesTimeout(operation: "reload") { finish in
            manager.loadFromPreferences { error in
                finish(error)
            }
        }
    }

    private func withPreferencesTimeout(
        operation: String,
        start: (@escaping (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = PreferenceOperationCompletion(continuation)
            let timeoutSeconds = Self.preferencesOperationTimeoutSeconds
            start { error in
                if let error {
                    _ = completion.resume(throwing: error)
                } else {
                    _ = completion.resume(returning: ())
                }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                _ = completion.resume(
                    throwing: PacketTunnelControllerError.preferencesTimedOut(operation)
                )
            }
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        guard let supportDir = AppModel.supportDirectory() else {
            return
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let logUrl = supportDir.appendingPathComponent("app-debug.log")
        appendIosDebugLog(message, to: logUrl)
        #endif
    }
}

private final class ProviderMessageCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Data?, Error>

    init(_ continuation: CheckedContinuation<Data?, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Data?) -> Bool {
        guard markCompleted() else {
            return false
        }
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard markCompleted() else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    private func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else {
            return false
        }
        completed = true
        return true
    }
}

private final class PreferenceOperationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Void) -> Bool {
        guard markCompleted() else {
            return false
        }
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard markCompleted() else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    private func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else {
            return false
        }
        completed = true
        return true
    }
}

private final class PreferenceManagerLoadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<[NETunnelProviderManager], Error>

    init(_ continuation: CheckedContinuation<[NETunnelProviderManager], Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning managers: [NETunnelProviderManager]) -> Bool {
        guard markCompleted() else {
            return false
        }
        continuation.resume(returning: managers)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard markCompleted() else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    private func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else {
            return false
        }
        completed = true
        return true
    }
}
