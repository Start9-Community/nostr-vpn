import Foundation
import UIKit

private let iosDebugLogLimitBytes = 1_048_576

func appendIosDebugLog(_ message: String, to logURL: URL) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else {
        return
    }
    let existingBytes = (
        try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber
    )?.intValue ?? 0
    if existingBytes + data.count > iosDebugLogLimitBytes {
        let previousURL = logURL.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
    }
    if FileManager.default.fileExists(atPath: logURL.path),
       let handle = try? FileHandle(forWritingTo: logURL)
    {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL, options: .atomic)
    }
}

extension AppModel {
    func qrMatrix(for text: String) -> QrMatrix {
        if fixtureMode {
            return ScreenshotFixtures.qrMatrix()
        }
        return core?.qrMatrix(text: text) ?? QrMatrix()
    }

    func copy(_ value: String) {
        guard !value.isEmpty else {
            return
        }
        UIPasteboard.general.string = value
        copiedValue = value
        copyClearTask?.cancel()
        copyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if self?.copiedValue == value {
                    self?.copiedValue = ""
                }
            }
        }
    }

    static func migrateLegacySupportDirectoryIfNeeded(to supportDir: URL) throws {
        let fileManager = FileManager.default
        let migrationMarker = supportDir.appendingPathComponent(
            ".legacy-private-container-migrated"
        )
        guard !fileManager.fileExists(atPath: migrationMarker.path) else {
            return
        }
        guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first
        else {
            return
        }
        let legacySupportDir = applicationSupport.appendingPathComponent(
            "Nostr VPN",
            isDirectory: true
        )
        let legacyConfig = legacySupportDir.appendingPathComponent(configFileName)
        guard legacySupportDir.resolvingSymlinksInPath() != supportDir.resolvingSymlinksInPath(),
              configurationHasNetworks(at: legacyConfig)
        else {
            return
        }

        for source in try fileManager.contentsOfDirectory(
            at: legacySupportDir,
            includingPropertiesForKeys: nil
        ) {
            let name = source.lastPathComponent
            if legacyMigrationExcludes(name) {
                continue
            }
            let destination = supportDir.appendingPathComponent(name)
            if name == configFileName {
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: .atomic)
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                if name == "cashu" || name == "\(configFileName).join-roster-outbox" {
                    try fileManager.removeItem(at: destination)
                } else {
                    continue
                }
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        try "migrated\n".write(
            to: migrationMarker,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func configurationHasNetworks(at url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains("[[networks]]") == true
    }

    private static func legacyMigrationExcludes(_ name: String) -> Bool {
        name == "app-debug.log"
            || name == "nvpn-pkt-debug.log"
            || name == mobileRuntimeStateFileName
            || name == "final-phone-status.json"
            || name == "ios-join-request.json"
            || name.hasPrefix("mobile-ios-")
    }

    static func seedMobileConfig(in supportDir: URL, deviceName: String) throws {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }

        let config = supportDir.appendingPathComponent(configFileName)
        guard !FileManager.default.fileExists(atPath: config.path) else {
            return
        }

        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try "node_name = \"\(escaped)\"\n".write(to: config, atomically: true, encoding: .utf8)
    }

    func refreshTunnelSidecarState() {
        guard state.vpnEnabled else {
            return
        }
        let refreshGeneration = tunnelStateRefreshGeneration
        refreshTunnelAppConfig(generation: refreshGeneration)
        refreshTunnelRuntimeState(generation: refreshGeneration)
    }

    private func refreshTunnelAppConfig(generation refreshGeneration: UInt64) {
        guard !tunnelAppConfigRefreshInFlight else {
            return
        }
        tunnelAppConfigRefreshInFlight = true
        Task { [weak self] in
            let appConfigToml = await self?.vpnController.takeAppConfigToml()
            let acceptance = await MainActor.run {
                guard let self,
                      self.tunnelStateRefreshGeneration == refreshGeneration
                else {
                    return (accepted: false, networkChanged: false)
                }
                let previousNetworkId = self.activeNetwork?.networkId ?? ""
                var wrote = false
                var appConfigAccepted = false
                if let appConfigToml {
                    let result = self.acceptTunnelAppConfig(appConfigToml)
                    appConfigAccepted = result.accepted
                    wrote = result.wrote
                }
                if wrote, let core = self.core {
                    self.adoptAppStoreCompatibleState(
                        core.refresh(),
                        core: core,
                        reason: "packet tunnel config"
                    )
                }
                let currentNetworkId = self.activeNetwork?.networkId ?? ""
                return (
                    accepted: appConfigAccepted,
                    networkChanged: wrote && previousNetworkId != currentNetworkId
                )
            }
            if acceptance.accepted {
                _ = await self?.vpnController.acknowledgeAppConfigToml()
            }
            await MainActor.run {
                guard let self,
                      self.tunnelStateRefreshGeneration == refreshGeneration
                else {
                    return
                }
                self.tunnelAppConfigRefreshInFlight = false
                if acceptance.networkChanged {
                    // A FIPS endpoint's discovery scope is bound to its network
                    // id. Restart exactly once after a join so the accepted
                    // roster does not remain on its QR/onboarding scope.
                    self.schedulePacketTunnelConfigSync(reason: "network joined", force: true)
                }
            }
        }
    }

    private func refreshTunnelRuntimeState(generation refreshGeneration: UInt64) {
        guard !tunnelRuntimeRefreshInFlight else {
            return
        }
        tunnelRuntimeRefreshInFlight = true
        Task { [weak self] in
            let runtimeJson = await self?.vpnController.runtimeStateJson()
            await MainActor.run {
                guard let self,
                      self.tunnelStateRefreshGeneration == refreshGeneration
                else {
                    return
                }
                self.tunnelRuntimeRefreshInFlight = false
                guard let runtimeJson,
                      self.writeTunnelRuntimeStateIfNeeded(runtimeJson)
                else {
                    return
                }
                if let core = self.core {
                    self.adoptAppStoreCompatibleState(
                        core.refresh(),
                        core: core,
                        reason: "packet tunnel runtime"
                    )
                }
            }
        }
    }

    private func writeTunnelRuntimeStateIfNeeded(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            return false
        }
        return writeSupportFileIfChanged(data, name: Self.mobileRuntimeStateFileName)
    }

    private func acceptTunnelAppConfig(_ toml: String) -> (accepted: Bool, wrote: Bool) {
        let trimmed = toml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("# failed") else {
            return (false, false)
        }
        guard let supportDir, let data = toml.data(using: .utf8) else {
            return (false, false)
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let url = supportDir.appendingPathComponent(Self.configFileName)
        if let existing = try? Data(contentsOf: url), existing == data {
            return (true, false)
        }
        do {
            try data.write(to: url, options: .atomic)
            debugLog("wrote tunnel sidecar file \(Self.configFileName)")
            return (true, true)
        } catch {
            debugLog("failed to write tunnel sidecar file \(Self.configFileName): \(String(describing: error))")
            return (false, false)
        }
    }

    private func writeSupportFileIfChanged(_ data: Data, name: String) -> Bool {
        guard let supportDir else {
            return false
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let url = supportDir.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: url), existing == data {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            debugLog("wrote tunnel sidecar file \(name)")
            return true
        } catch {
            debugLog("failed to write tunnel sidecar file \(name): \(String(describing: error))")
            return false
        }
    }

    nonisolated static func supportDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Nostr VPN", isDirectory: true)
    }

    static func deviceName() -> String {
        let preferred = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            return preferred
        }

        let model = UIDevice.current.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "iOS device" : model
    }

    nonisolated static func screenshotTabArgument() -> String? {
        argumentValue(after: "--nvpn-screenshot-tab", in: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func fixtureModeRequested() -> Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--nvpn-fixture-mode") {
            return true
        }
        let raw = ProcessInfo.processInfo.environment["NVPN_IOS_FIXTURE_MODE"] ?? ""
        return ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        #else
        return false
        #endif
    }

    func debugLog(_ message: String) {
        #if DEBUG
        guard let supportDir else {
            return
        }
        let logUrl = supportDir.appendingPathComponent("app-debug.log")
        appendIosDebugLog(message, to: logUrl)
        #endif
    }
}
