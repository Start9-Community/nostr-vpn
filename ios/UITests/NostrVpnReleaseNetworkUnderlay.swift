import Foundation
import Network
import XCTest

private final class NostrVpnReleasePhysicalPathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "fi.siriusbusiness.nvpn.release-underlay"
    )

    init() {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    /// Returns the monotonic start of the last path check that still failed.
    /// This lower bound makes the measured recovery conservatively long.
    func waitForWiFi(
        timeout: TimeInterval,
        initialLowerBound: TimeInterval? = nil
    ) -> TimeInterval? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastFailedCheckStarted = initialLowerBound
            ?? ProcessInfo.processInfo.systemUptime
        repeat {
            let checkStarted = ProcessInfo.processInfo.systemUptime
            let path = monitor.currentPath
            if path.status == .satisfied,
               path.usesInterfaceType(.wifi),
               !path.usesInterfaceType(.cellular)
            {
                return lastFailedCheckStarted
            }
            lastFailedCheckStarted = checkStarted
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    func waitForOutage(timeout: TimeInterval) -> TimeInterval? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let observed = ProcessInfo.processInfo.systemUptime
            let path = monitor.currentPath
            if path.status != .satisfied,
               !path.usesInterfaceType(.wifi),
               !path.usesInterfaceType(.cellular)
            {
                return observed
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }
}

extension NostrVpnReleaseNetworkUITests {
    func driveUnderlayChanges(_ spec: Spec) throws {
        let associationTimeout = TimeInterval(spec.underlayAssociationTimeoutSeconds)
        let pathMonitor = NostrVpnReleasePhysicalPathMonitor()
        defer { pathMonitor.cancel() }

        let originalSsid = try selectedWiFiSSID()
        guard !originalSsid.isEmpty,
              pathMonitor.waitForWiFi(timeout: 8) != nil
        else {
            throw gateError("iPhone did not begin on a validated Wi-Fi path")
        }
        try persistOriginalWiFiForCleanup(originalSsid)
        app.activate()
        guard waitForApplicationState(.runningForeground, timeout: 10),
              waitForVPNState(on: true, timeout: 8)
        else {
            throw gateError("Release app/VPN did not foreground before the radio bounce")
        }
        try proveExit(spec, label: "wifi-before-radio-off")

        var wifiNeedsRestoration = false
        defer {
            if wifiNeedsRestoration {
                do {
                    try setWiFiEnabled(true)
                    let pathRestored = pathMonitor.waitForWiFi(
                        timeout: associationTimeout
                    ) != nil
                    let ssidRestored = try selectedWiFiSSID() == originalSsid
                    if !pathRestored || !ssidRestored {
                        XCTFail("Radio-bounce cleanup did not restore the original Wi-Fi")
                    }
                } catch {
                    XCTFail("Radio-bounce cleanup could not restore Wi-Fi")
                }
            }
        }

        emit("NVPN_IOS_UNDERLAY_SWITCH_1_REQUESTED_MS=\(millisecondsSinceEpoch())")
        wifiNeedsRestoration = true
        try setWiFiEnabled(false)
        guard pathMonitor.waitForOutage(timeout: 8) != nil else {
            throw gateError("Wi-Fi off did not produce a no-cellular physical outage")
        }
        emit("NVPN_IOS_UNDERLAY_SWITCH_1_OUTAGE_MS=\(millisecondsSinceEpoch())")
        var payloadOutageObserved = false
        do {
            _ = try NostrVpnReleaseNetworkProbe.requireUDPEcho(
                host: spec.udpHost,
                port: spec.udpPort,
                label: "\(spec.caseName)-wifi-radio-off-must-fail",
                timeout: 1
            )
        } catch {
            payloadOutageObserved = true
        }
        guard payloadOutageObserved else {
            throw gateError("WireGuard payload survived Wi-Fi off via an undeclared fallback")
        }
        emit("NVPN_IOS_UNDERLAY_SWITCH_1_NO_VALIDATED_PHYSICAL_FALLBACK=1")

        // End the proven outage window before Settings enables the radio.
        emit(
            "NVPN_IOS_UNDERLAY_SWITCH_1_RECOVERY_REQUESTED_MS="
                + "\(millisecondsSinceEpoch())"
        )
        try setWiFiEnabled(true)
        guard pathMonitor.waitForWiFi(timeout: associationTimeout) != nil else {
            throw gateError("Wi-Fi did not return after the radio was enabled")
        }
        let underlayValidatedUptime = ProcessInfo.processInfo.systemUptime
        emit(
            "NVPN_IOS_UNDERLAY_SWITCH_1_UNDERLAY_VALIDATED_MS="
                + "\(millisecondsSinceEpoch())"
        )

        let dnsReceipt = try NostrVpnReleaseNetworkProbe.exerciseFreshDNSQuery(
            baseHost: spec.resolverQueryHost,
            expectedAddress: spec.udpHost
        )
        emit(
            "NVPN_IOS_UNDERLAY_SWITCH_1_FRESH_DNS_QUERY="
                + dnsReceipt.queryHost
        )
        let payloadUptime = try NostrVpnReleaseNetworkProbe.requireUDPEcho(
            host: spec.udpHost,
            port: spec.udpPort,
            label: "\(spec.caseName)-wifi-radio-on-first-payload",
            timeout: 4
        )
        try assertPayloadRecovery(
            cycle: 1,
            underlayValidatedUptime: underlayValidatedUptime,
            dnsUptime: dnsReceipt.completedUptime,
            payloadUptime: payloadUptime
        )
        guard try selectedWiFiSSID() == originalSsid else {
            throw gateError("iPhone did not restore its original Wi-Fi")
        }
        emit("NVPN_IOS_UNDERLAY_SWITCH_1_ORIGINAL_WIFI_RESTORED=1")
        wifiNeedsRestoration = false
        app.activate()
        guard waitForApplicationState(.runningForeground, timeout: 10),
              waitForVPNState(on: true, timeout: 8)
        else {
            throw gateError("Release app/VPN did not foreground after Wi-Fi returned")
        }
        try proveExit(spec, label: "wifi-radio-on")
        emit("NVPN_IOS_UNDERLAY_SWITCH_1_VERIFIED_MS=\(millisecondsSinceEpoch())")
    }

    func waitForPhysicalPath(
        required: NWInterface.InterfaceType,
        excluded: NWInterface.InterfaceType?,
        timeout: TimeInterval
    ) -> TimeInterval? {
        let monitor = NostrVpnReleasePhysicalPathMonitor()
        defer { monitor.cancel() }
        guard required == .wifi, excluded == nil || excluded == .cellular else {
            return nil
        }
        return monitor.waitForWiFi(timeout: timeout)
    }

    func assertPayloadRecovery(
        cycle: Int,
        underlayValidatedUptime: TimeInterval,
        dnsUptime: TimeInterval,
        payloadUptime: TimeInterval
    ) throws {
        guard dnsUptime >= underlayValidatedUptime,
              payloadUptime >= dnsUptime
        else {
            throw gateError("Radio-on payload preceded validated Wi-Fi")
        }
        let recoveryMilliseconds = Int64(
            ((payloadUptime - underlayValidatedUptime) * 1_000).rounded(.up)
        )
        guard recoveryMilliseconds <= 4_000 else {
            throw gateError(
                "Wi-Fi radio-on DNS/WireGuard recovery took "
                    + "\(recoveryMilliseconds)ms"
            )
        }
        emit(
            "NVPN_IOS_UNDERLAY_SWITCH_\(cycle)_PAYLOAD_RECOVERY_MS="
                + "\(recoveryMilliseconds)"
        )
    }

    func setWiFiEnabled(_ enabled: Bool) throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        guard waitForApplicationState(settings, .runningForeground, timeout: 8) else {
            throw gateError("Settings did not foreground for the Wi-Fi radio change")
        }
        let toggle = try openWiFiSettings(settings)
        if toggleIsOn(toggle) != enabled {
            toggle.tap()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if toggleIsOn(toggle) == enabled {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw gateError("Settings Wi-Fi switch did not reach the requested state")
    }

    func selectedWiFiSSID() throws -> String {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        guard waitForApplicationState(settings, .runningForeground, timeout: 8) else {
            throw gateError("Settings did not foreground for Wi-Fi readback")
        }
        _ = try openWiFiSettings(settings)
        for cell in settings.cells.allElementsBoundByIndex where wifiCellIsSelected(cell) {
            let labels = cell.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .filter { !$0.isEmpty }
            if let ssid = labels.first {
                return ssid
            }
        }
        throw gateError("Settings did not expose the selected Wi-Fi")
    }

    func openWiFiSettings(_ settings: XCUIApplication) throws -> XCUIElement {
        try normalizeSettingsRoot(settings)
        let rows = settings.cells.containing(
            .staticText,
            identifier: "Wi-Fi"
        )
        guard rows.count == 1 else {
            throw gateError("Settings root did not expose one Wi-Fi row")
        }
        let row = rows.firstMatch
        let label = row.staticTexts["Wi-Fi"].firstMatch
        guard label.isHittable else {
            throw gateError("Settings Wi-Fi label was not hittable")
        }
        label.tap()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let back = settings.navigationBars.buttons.firstMatch
            guard back.exists, back.isHittable else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let nativeSwitches = settings.switches.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
            if nativeSwitches.count == 1 {
                return nativeSwitches[0]
            }
            let binaryControls = settings.descendants(matching: .any)
                .allElementsBoundByIndex
                .filter { element in
                    element.exists && element.isHittable
                        && binaryControlState(element) != nil
                }
            if binaryControls.count == 1 {
                return binaryControls[0]
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw gateError("Settings did not expose one public Wi-Fi toggle")
    }

    func binaryControlState(_ element: XCUIElement) -> Bool? {
        guard let rawValue = element.value else {
            return nil
        }
        switch String(describing: rawValue).trimmingCharacters(in: .whitespaces)
            .lowercased()
        {
        case "1", "on", "true", "yes":
            return true
        case "0", "off", "false", "no":
            return false
        default:
            return nil
        }
    }

    func normalizeSettingsRoot(_ settings: XCUIApplication) throws {
        let wifiRows = settings.cells.containing(
            .staticText,
            identifier: "Wi-Fi"
        )
        var remainingDepth = 8
        while wifiRows.count != 1 {
            guard remainingDepth > 0 else {
                throw gateError("Settings root was more than eight pages away")
            }
            let back = settings.navigationBars.buttons.firstMatch
            guard back.waitForExistence(timeout: 2), back.isHittable else {
                throw gateError("Settings could not return to its root page")
            }
            back.tap()
            remainingDepth -= 1
        }
    }

    func wifiCellIsSelected(_ cell: XCUIElement) -> Bool {
        if cell.isSelected {
            return true
        }
        let summary = "\(cell.label) \(cell.value as? String ?? "")".lowercased()
        if summary.contains("selected") || summary.contains("connected") {
            return true
        }
        let selected = cell.images.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
                "selected",
                "checkmark"
            )
        ).firstMatch
        return selected.exists
    }

    func persistOriginalWiFiForCleanup(_ ssid: String) throws {
        try Data(ssid.utf8).write(
            to: originalWiFiCleanupURL,
            options: .atomic
        )
    }

    func originalWiFiForCleanup() throws -> String {
        let data = try Data(contentsOf: originalWiFiCleanupURL)
        guard let ssid = String(data: data, encoding: .utf8), !ssid.isEmpty else {
            throw gateError("Original Wi-Fi cleanup state was invalid")
        }
        return ssid
    }

    func hasOriginalWiFiForCleanup() -> Bool {
        FileManager.default.fileExists(atPath: originalWiFiCleanupURL.path)
    }

    func clearOriginalWiFiCleanup() throws {
        if FileManager.default.fileExists(atPath: originalWiFiCleanupURL.path) {
            try FileManager.default.removeItem(at: originalWiFiCleanupURL)
        }
    }

    var originalWiFiCleanupURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nvpn-underlay-original-wifi")
    }
}
