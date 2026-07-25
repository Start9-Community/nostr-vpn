import Foundation

extension AppModel {
    func runDebugStartJoinAdvertising(resultName: String) async {
        #if DEBUG
        let startedAt = Date()
        dispatch(
            NativeActions.startJoinRequestBroadcast(),
            status: "Advertising nearby"
        )
        var result: [String: Any] = [
            "ok": false,
            "phase": "waiting",
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
        ]
        writeDebugProbeResult(result, name: resultName)
        let deadline = startedAt.addingTimeInterval(15)
        while Date() < deadline {
            let status = await vpnController.statusRawValue()
            if state.joinRequestBroadcastActive, status == 3 {
                result["ok"] = true
                result["phase"] = "finished"
                result["packetTunnelStatusRawValue"] = status
                result["joinRequestBroadcastActive"] = true
                result["elapsedMs"] = Self.elapsedMilliseconds(since: startedAt)
                writeDebugProbeResult(result, name: resultName)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        result["phase"] = "finished"
        result["error"] = state.error.isEmpty
            ? "join advertising did not start a connected packet tunnel"
            : state.error
        result["packetTunnelStatusRawValue"] = await vpnController.statusRawValue() ?? -1
        result["joinRequestBroadcastActive"] = state.joinRequestBroadcastActive
        writeDebugProbeResult(result, name: resultName)
        #endif
    }

    func selectDebugNetworkIfPresent(arguments: [String]) -> Bool {
        #if DEBUG
        guard let meshNetworkId = Self.base64DebugArgument(
            after: "--nvpn-debug-select-network-base64",
            in: arguments
        ) else {
            return false
        }
        let resultName = Self.argumentValue(
            after: "--nvpn-debug-select-network-result",
            in: arguments
        )
        refresh()
        guard let network = state.networks.first(where: {
            $0.networkId == meshNetworkId || $0.id == meshNetworkId
        }) else {
            writeDebugNetworkSelectionResult(
                requestedNetworkId: meshNetworkId,
                resultName: resultName,
                defaultError: "Network not found in loaded app state"
            )
            debugLog(
                "debug network selection failed: mesh not found "
                    + "loadedNetworks=\(state.networks.count) error=\(state.error)"
            )
            return true
        }
        dispatch(NativeActions.setNetworkEnabled(network.id, true))
        refresh()
        writeDebugNetworkSelectionResult(
            requestedNetworkId: meshNetworkId,
            resultName: resultName
        )
        return true
        #else
        return false
        #endif
    }

    #if DEBUG
    private func writeDebugNetworkSelectionResult(
        requestedNetworkId: String,
        resultName: String?,
        defaultError: String = ""
    ) {
        guard let resultName else {
            return
        }
        let enabledNetworkCount = state.networks.filter(\.enabled).count
        let activeNetworkId = activeNetwork?.networkId ?? ""
        let error = state.error.isEmpty ? defaultError : state.error
        writeDebugProbeResult([
            "ok": error.isEmpty
                && activeNetworkId == requestedNetworkId
                && enabledNetworkCount == 1,
            "requestedNetworkId": requestedNetworkId,
            "activeNetworkId": activeNetworkId,
            "activeSavedNetworkId": activeNetwork?.id ?? "",
            "enabledNetworkCount": enabledNetworkCount,
            "loadedNetworkCount": state.networks.count,
            "error": error,
        ], name: resultName)
    }
    #endif

    func importDebugJoinRequestIfPresent(arguments: [String]) -> Bool {
        #if DEBUG
        guard let request = Self.base64DebugArgument(
            after: "--nvpn-debug-import-join-request-base64",
            in: arguments
        ),
            !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        dispatch(NativeActions.importJoinRequest(request), status: "Adding device")
        refresh()
        return true
        #else
        return false
        #endif
    }

    func exportDebugJoinRequestIfRequested(arguments: [String]) -> Bool {
        #if DEBUG
        guard let resultName = Self.argumentValue(
            after: "--nvpn-debug-export-join-request",
            in: arguments
        ) else {
            return false
        }
        refresh()
        writeDebugProbeResult([
            "joinRequest": state.joinRequestQrCodeOrLink,
            "deviceId": state.ownNpub,
            "error": state.error,
        ], name: resultName)
        return true
        #else
        return false
        #endif
    }

    func waitForDebugJoinedNetworkIfRequested(arguments: [String]) -> Bool {
        #if DEBUG
        guard let networkId = Self.base64DebugArgument(
            after: "--nvpn-debug-wait-for-joined-network-base64",
            in: arguments
        ),
        let resultName = Self.argumentValue(
            after: "--nvpn-debug-wait-for-joined-network-result",
            in: arguments
        ),
        !networkId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        let timeoutSeconds = Self.argumentValue(
            after: "--nvpn-debug-wait-for-joined-network-timeout-seconds",
            in: arguments
        ).flatMap(Double.init) ?? 15
        Task {
            await runDebugWaitForJoinedNetwork(
                networkId: networkId,
                resultName: resultName,
                timeoutSeconds: min(max(timeoutSeconds, 1), 30)
            )
        }
        return true
        #else
        return false
        #endif
    }

    #if DEBUG
    private func runDebugWaitForJoinedNetwork(
        networkId: String,
        resultName: String,
        timeoutSeconds: Double
    ) async {
        let startedAt = Date()
        var result: [String: Any] = [
            "ok": false,
            "phase": "waiting",
            "requestedNetworkId": networkId,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
        ]
        writeDebugProbeResult(result, name: resultName)

        refresh()
        if activeNetwork?.networkId == networkId,
           !debugConfigHasSignedRoster(networkId: networkId)
        {
            schedulePacketTunnelConfigSync(reason: "debug joined-network wait", force: true)
        }

        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            refresh()
            try? await Task.sleep(nanoseconds: 250_000_000)
            refresh()
            if debugConfigHasSignedRoster(networkId: networkId) {
                result["ok"] = true
                result["phase"] = "finished"
                result["activeNetworkId"] = activeNetwork?.networkId ?? ""
                result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
                result["elapsedMs"] = Self.elapsedMilliseconds(since: startedAt)
                if let status = await vpnController.statusRawValue() {
                    result["packetTunnelStatusRawValue"] = status
                }
                writeDebugProbeResult(result, name: resultName)
                return
            }
        }

        result["phase"] = "finished"
        result["activeNetworkId"] = activeNetwork?.networkId ?? ""
        result["error"] = state.error.isEmpty
            ? "signed roster did not arrive within \(Int(timeoutSeconds)) seconds"
            : state.error
        result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        result["elapsedMs"] = Self.elapsedMilliseconds(since: startedAt)
        if let status = await vpnController.statusRawValue() {
            result["packetTunnelStatusRawValue"] = status
        }
        writeDebugProbeResult(result, name: resultName)
    }

    private func debugConfigHasSignedRoster(networkId: String) -> Bool {
        guard let supportDir,
              let text = try? String(
                contentsOf: supportDir.appendingPathComponent(Self.configFileName),
                encoding: .utf8
              )
        else {
            return false
        }
        let escapedNetworkId = NSRegularExpression.escapedPattern(for: networkId)
        let requiredPatterns = [
            #"(?m)^\s*enabled\s*=\s*true\s*(?:#.*)?$"#,
            #"(?m)^\s*network_id\s*=\s*""# + escapedNetworkId + #""\s*(?:#.*)?$"#,
            #"(?m)^\s*shared_roster_updated_at\s*=\s*[1-9][0-9]*\s*(?:#.*)?$"#,
            #"(?m)^\s*shared_roster_signed_by\s*=\s*"[^"]+"\s*(?:#.*)?$"#,
        ]
        return text.components(separatedBy: "[[networks]]").dropFirst().contains { section in
            requiredPatterns.allSatisfy { pattern in
                section.range(of: pattern, options: .regularExpression) != nil
            }
        }
    }
    #endif

    func manualDebugJoinIfPresent(arguments: [String]) -> Bool {
        #if DEBUG
        guard let admin = Self.base64DebugArgument(
            after: "--nvpn-debug-manual-join-admin-base64",
            in: arguments
        ),
            let networkId = Self.base64DebugArgument(
                after: "--nvpn-debug-manual-join-network-base64",
                in: arguments
            ),
            !admin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !networkId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        dispatch(NativeActions.manualAddNetwork(adminNpub: admin, meshNetworkId: networkId))
        refresh()
        return true
        #else
        return false
        #endif
    }

    func addDebugParticipantIfPresent(arguments: [String]) -> Bool {
        #if DEBUG
        guard let deviceId = Self.base64DebugArgument(
            after: "--nvpn-debug-add-participant-base64",
            in: arguments
        ),
            let networkId = activeNetwork?.id,
            !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        dispatch(NativeActions.addParticipant(networkId: networkId, npub: deviceId, alias: ""))
        refresh()
        return true
        #else
        return false
        #endif
    }

    func removeDebugParticipantIfPresent(arguments: [String]) -> Bool {
        #if DEBUG
        guard let deviceId = Self.base64DebugArgument(
            after: "--nvpn-debug-remove-participant-base64",
            in: arguments
        ),
            let networkId = activeNetwork?.id,
            !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        dispatch(NativeActions.removeParticipant(networkId: networkId, npub: deviceId))
        refresh()
        return true
        #else
        return false
        #endif
    }

    func removeDebugActiveNetworkIfRequested(arguments: [String]) -> Bool {
        #if DEBUG
        guard arguments.contains("--nvpn-debug-remove-active-network"),
              let networkId = activeNetwork?.id
        else {
            return false
        }
        dispatch(NativeActions.removeNetwork(networkId))
        refresh()
        return true
        #else
        return false
        #endif
    }

    func addDebugNetworkIfPresent(arguments: [String]) -> Bool {
        #if DEBUG
        guard let name = Self.argumentValue(after: "--nvpn-debug-add-network", in: arguments) else {
            return false
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        dispatch(NativeActions.addNetwork(normalized.isEmpty ? "iOS smoke" : normalized))
        refresh()
        return true
        #else
        return false
        #endif
    }

    nonisolated private static func base64DebugArgument(
        after name: String,
        in arguments: [String]
    ) -> String? {
        guard let encoded = argumentValue(after: name, in: arguments),
              let data = Data(base64Encoded: encoded)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
