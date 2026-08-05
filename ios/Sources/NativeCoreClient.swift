import Foundation

final class NativeCoreClient {
    private var handle: OpaquePointer?
    private let dataDir: String

    init(dataDir: String, appVersion: String) {
        self.dataDir = dataDir
        handle = dataDir.withCString { dataDirPointer in
            appVersion.withCString { versionPointer in
                nostr_vpn_app_new(dataDirPointer, versionPointer)
            }
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else {
            return
        }
        nostr_vpn_app_free(handle)
        self.handle = nil
    }

    func state() -> AppState {
        parseState(consume(nostr_vpn_app_state_json(requireHandle())))
    }

    func refresh() -> AppState {
        parseState(consume(nostr_vpn_app_refresh_json(requireHandle())))
    }

    func dispatch(_ action: [String: Any]) -> AppState {
        guard JSONSerialization.isValidJSONObject(action),
              let data = try? JSONSerialization.data(withJSONObject: action),
              let json = String(data: data, encoding: .utf8)
        else {
            var state = state()
            state.error = "Invalid native action JSON"
            return state
        }

        return parseState(
            json.withCString { actionPointer in
                consume(nostr_vpn_app_dispatch_json(requireHandle(), actionPointer))
            }
        )
    }

    func qrMatrix(text: String) -> QrMatrix {
        let json = text.withCString { textPointer in
            consume(nostr_vpn_qr_matrix_json(textPointer))
        }
        guard let data = json.data(using: .utf8),
              let matrix = try? JSONDecoder().decode(QrMatrix.self, from: data)
        else {
            return QrMatrix()
        }
        return matrix
    }

    static func decodeQrImage(path: String) -> QrDecodeResult {
        let json = path.withCString { pathPointer in
            consumeQrDecodeResult(nostr_vpn_decode_qr_image_json(pathPointer))
        }
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(QrDecodeResult.self, from: data)
        else {
            return QrDecodeResult(error: "Invalid QR decode response")
        }
        return result
    }

    private static func consumeQrDecodeResult(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else {
            return ""
        }
        defer { nostr_vpn_string_free(pointer) }
        return String(cString: pointer)
    }

    func mobileTunnelConfigJson() -> String {
        dataDir.withCString { dataDirPointer in
            consume(nostr_vpn_mobile_tunnel_config_json(dataDirPointer))
        }
    }

    func mobileTunnelProviderOptionsConfigJson() -> String {
        dataDir.withCString { dataDirPointer in
            consume(nostr_vpn_mobile_tunnel_provider_options_config_json(dataDirPointer))
        }
    }

    private func parseState(_ json: String) -> AppState {
        guard let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else {
            var state = AppState()
            state.error = "Invalid native app state"
            return state
        }
        return state
    }

    private func requireHandle() -> OpaquePointer? {
        handle
    }

    private func consume(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else {
            return ""
        }
        defer { nostr_vpn_string_free(pointer) }
        return String(cString: pointer)
    }
}

enum NativeActions {
    static func connectVpn() -> [String: Any] {
        ["type": "connect_vpn"]
    }

    static func disconnectVpn() -> [String: Any] {
        ["type": "disconnect_vpn"]
    }

    static func importJoinRequest(_ request: String) -> [String: Any] {
        ["type": "import_join_request", "request": request]
    }

    static func addNetwork(_ name: String) -> [String: Any] {
        ["type": "add_network", "name": name]
    }

    static func manualAddNetwork(adminNpub: String, meshNetworkId: String) -> [String: Any] {
        [
            "type": "manual_add_network",
            "adminNpub": adminNpub,
            "meshNetworkId": meshNetworkId,
        ]
    }

    static func setNetworkEnabled(_ networkId: String, _ enabled: Bool) -> [String: Any] {
        ["type": "set_network_enabled", "networkId": networkId, "enabled": enabled]
    }

    static func removeNetwork(_ networkId: String) -> [String: Any] {
        ["type": "remove_network", "networkId": networkId]
    }

    static func updateSettings(_ patch: [String: Any]) -> [String: Any] {
        ["type": "update_settings", "patch": patch]
    }

    static func addParticipant(networkId: String, npub: String, alias: String) -> [String: Any] {
        [
            "type": "add_participant",
            "networkId": networkId,
            "npub": npub,
            "alias": alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : alias,
        ]
    }

    static func setParticipantAlias(npub: String, alias: String) -> [String: Any] {
        ["type": "set_participant_alias", "npub": npub, "alias": alias]
    }

    static func setParticipantEndpointHints(npub: String, endpointHints: [String]) -> [String: Any] {
        ["type": "set_participant_endpoint_hints", "npub": npub, "endpointHints": endpointHints]
    }

    static func addAdmin(networkId: String, npub: String) -> [String: Any] {
        ["type": "add_admin", "networkId": networkId, "npub": npub]
    }

    static func removeAdmin(networkId: String, npub: String) -> [String: Any] {
        ["type": "remove_admin", "networkId": networkId, "npub": npub]
    }

    static func removeParticipant(networkId: String, npub: String) -> [String: Any] {
        ["type": "remove_participant", "networkId": networkId, "npub": npub]
    }

}
