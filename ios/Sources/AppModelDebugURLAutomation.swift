import Foundation

extension AppModel {
    nonisolated static func debugArguments(fromBase64URL encoded: String) -> [String]? {
        var padded = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded),
              let value = try? JSONSerialization.jsonObject(with: data),
              let arguments = value as? [String],
              !arguments.isEmpty,
              arguments.count <= 64,
              arguments.allSatisfy({ !$0.contains("\0") }),
              arguments[0].hasPrefix("--nvpn-debug-") || arguments[0].hasPrefix("--nvpn-")
        else {
            return nil
        }
        return arguments
    }

    nonisolated static func redactedDebugArguments(_ arguments: [String]) -> [String] {
        let sensitiveFlags = [
            "--nvpn-debug-exit-node",
            "--nvpn-debug-fetch-url",
            "--nvpn-debug-direct-fetch-url",
            "--nvpn-debug-direct-resolve-host",
            "--nvpn-debug-result",
            "--nvpn-debug-idle-cpu-result",
            "--nvpn-debug-tun-probe-target",
            "--nvpn-debug-wireguard-config-base64",
            "--nvpn-debug-wireguard-config-file",
            "--nvpn-debug-exit-dns-custom-doh-url",
            "--nvpn-debug-exit-dns-custom-doh-bootstrap-ips",
            "--nvpn-debug-exit-dns-through-exit-servers",
            "--nvpn-debug-connect-result",
            "--nvpn-debug-runtime-result",
        ]
        var output: [String] = []
        var redactNext = false
        for argument in arguments {
            if redactNext {
                output.append("<redacted>")
                redactNext = false
                continue
            }
            if let flag = sensitiveFlags.first(where: { argument.hasPrefix($0 + "=") }) {
                output.append("\(flag)=<redacted>")
                continue
            }
            output.append(argument)
            if sensitiveFlags.contains(argument) {
                redactNext = true
            }
        }
        return output
    }

    nonisolated static func debugExitSettingsPatch(
        arguments: [String],
        supportDir: URL?
    ) -> [String: Any] {
        var patch: [String: Any] = [:]
        let exitNode = argumentValue(after: "--nvpn-debug-exit-node", in: arguments)
        let wireGuardConfig = wireGuardConfig(from: arguments, supportDir: supportDir)
        if let wireGuardConfig,
           !wireGuardConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            patch.merge([
                "internetSource": "wireguard",
                "wireguardExitConfig": wireGuardConfig,
                "wireguardExitEnabled": true,
                "exitNode": "",
            ]) { _, new in new }
        } else if let exitNode, !exitNode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            patch.merge([
                "internetSource": "private_vpn",
                "exitNode": exitNode,
                "wireguardExitEnabled": false,
                "exitNodeLeakProtection": true,
            ]) { _, new in new }
        } else if arguments.contains("--nvpn-debug-clear-exit") {
            patch.merge([
                "internetSource": "direct",
                "exitNode": "",
                "wireguardExitEnabled": false,
                "exitNodeLeakProtection": false,
            ]) { _, new in new }
        }
        if let mode = argumentValue(after: "--nvpn-debug-exit-dns-mode", in: arguments) {
            patch["exitDnsMode"] = mode
            patch["exitDnsDohProvider"] =
                argumentValue(after: "--nvpn-debug-exit-dns-doh-provider", in: arguments)
                ?? "cloudflare"
            patch["exitDnsCustomDohUrl"] =
                argumentValue(after: "--nvpn-debug-exit-dns-custom-doh-url", in: arguments)
                ?? ""
            patch["exitDnsCustomDohBootstrapIps"] = argumentValue(
                after: "--nvpn-debug-exit-dns-custom-doh-bootstrap-ips",
                in: arguments
            ) ?? ""
            patch["exitDnsThroughExitServers"] = argumentValue(
                after: "--nvpn-debug-exit-dns-through-exit-servers",
                in: arguments
            ) ?? ""
        }
        return patch
    }

    func debugExitDnsStateResult() -> [String: Any] {
        [
            "internetSource": state.internetSource,
            "exitDnsMode": state.exitDnsMode,
            "exitDnsDohProvider": state.exitDnsDohProvider,
            "exitDnsCustomDohUrl": state.exitDnsCustomDohUrl,
            "exitDnsCustomDohBootstrapIps": state.exitDnsCustomDohBootstrapIps,
            "exitDnsThroughExitServers": state.exitDnsThroughExitServers,
        ]
    }

    func runDebugDirectWhileConnected(
        waitSeconds: Double,
        fetchUrl: String?,
        resolveHost: String?
    ) async -> [String: Any] {
        statusMessage = "Waiting for This device selection"
        let deadline = Date().addingTimeInterval(waitSeconds)
        var tunnelStatus = await vpnController.statusRawValue()
        var uiSelectionObserved = false
        while Date() < deadline {
            refresh()
            tunnelStatus = await vpnController.statusRawValue()
            if tunnelStatus == 3,
               state.vpnEnabled,
               state.internetSource == "direct" {
                uiSelectionObserved = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        refresh()
        var result: [String: Any] = [
            "directWhileTunnelUiSelectionObserved": uiSelectionObserved,
            "directWhileTunnelVpnEnabled": state.vpnEnabled,
            "directWhileTunnelInternetSource": state.internetSource,
            "directWhileTunnelWireguardExitEnabled": state.wireguardExitEnabled,
        ]
        if let tunnelStatus {
            result["directWhileTunnelPacketTunnelStatusRawValue"] = tunnelStatus
        }
        if let routeState = await vpnController.installedRouteState() {
            result["directWhileTunnelHasDefaultRoute"] = routeState.hasDefaultRoute
            result["directWhileTunnelHasWireGuardExit"] = routeState.hasWireGuardExit
        }
        for (key, value) in await debugNetworkProbe(
            urlString: fetchUrl,
            resolveHost: resolveHost
        ) {
            result["directWhileTunnel\(key.prefix(1).uppercased())\(key.dropFirst())"] = value
        }
        statusMessage = "Direct Internet verified"
        return result
    }
}
