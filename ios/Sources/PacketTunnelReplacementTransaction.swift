import Foundation

struct PacketTunnelReplacementStateStore {
    static let markerFileName = "packet-tunnel-restart-required"

    private let markerURL: URL

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    func markRestartRequired() throws {
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("restart-required\n".utf8).write(to: markerURL, options: .atomic)
    }

    func clearRestartRequired() throws {
        if restartRequired() {
            try FileManager.default.removeItem(at: markerURL)
        }
    }

    func restartRequired() -> Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }
}

struct PacketTunnelReplacementError: LocalizedError {
    let operationDescription: String
    let cleanupDescription: String?

    var disconnectConfirmed: Bool {
        cleanupDescription == nil
    }

    var errorDescription: String? {
        if let cleanupDescription {
            return "VPN update failed (\(operationDescription)); disconnect could not be confirmed (\(cleanupDescription))"
        }
        return "VPN update failed (\(operationDescription)); VPN was disconnected safely"
    }
}

struct PacketTunnelStartPreparation {
    func perform<Value>(
        operation: () async throws -> Value,
        confirmDisconnected: () async throws -> Void
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as CancellationError {
            throw error
        } catch let error as PacketTunnelReplacementError {
            throw error
        } catch {
            let operationError = error
            do {
                try await confirmDisconnected()
            } catch {
                throw PacketTunnelReplacementError(
                    operationDescription: String(describing: operationError),
                    cleanupDescription: String(describing: error)
                )
            }
            throw PacketTunnelReplacementError(
                operationDescription: String(describing: operationError),
                cleanupDescription: nil
            )
        }
    }
}

struct PacketTunnelReplacementTransaction {
    let state: PacketTunnelReplacementStateStore

    func perform(
        replacingActiveTunnel: Bool,
        saveAndReload: () async throws -> Void,
        disconnect: () async throws -> Void,
        startAndWait: () async throws -> Void
    ) async throws {
        try state.markRestartRequired()
        do {
            try await saveAndReload()
            if replacingActiveTunnel {
                try await disconnect()
            }
            try await startAndWait()
            try state.clearRestartRequired()
        } catch {
            let operationError = error
            do {
                try await disconnect()
            } catch {
                throw PacketTunnelReplacementError(
                    operationDescription: String(describing: operationError),
                    cleanupDescription: String(describing: error)
                )
            }
            throw PacketTunnelReplacementError(
                operationDescription: String(describing: operationError),
                cleanupDescription: nil
            )
        }
    }
}
