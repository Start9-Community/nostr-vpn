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
    /// This conservative lower bound prevents delayed monitor delivery from
    /// making payload recovery appear faster than it was.
    func waitFor(
        required: NWInterface.InterfaceType,
        excluded: NWInterface.InterfaceType?,
        timeout: TimeInterval
    ) -> TimeInterval? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastFailedCheckStarted = ProcessInfo.processInfo.systemUptime
        repeat {
            let checkStarted = ProcessInfo.processInfo.systemUptime
            let path = monitor.currentPath
            let excludedPresent = excluded.map(path.usesInterfaceType) ?? false
            if path.status == .satisfied,
               path.usesInterfaceType(required),
               !excludedPresent
            {
                return lastFailedCheckStarted
            }
            lastFailedCheckStarted = checkStarted
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

        guard try selectedWiFiSSID() == spec.underlayHomeSsid else {
            throw gateError("iPhone did not start on the exact declared home Wi-Fi")
        }
        guard pathMonitor.waitFor(
            required: .wifi,
            excluded: nil,
            timeout: 8
        ) != nil else {
            throw gateError("iPhone did not begin on the exact home Wi-Fi")
        }
        app.activate()
        guard waitForApplicationState(.runningForeground, timeout: 10),
              waitForVPNState(on: true, timeout: 8)
        else {
            throw gateError("Release app/VPN did not foreground on home Wi-Fi")
        }
        try proveExit(spec, label: "home-wifi-before-switch")

        var wifiNeedsRestoration = false
        defer {
            if wifiNeedsRestoration {
                do {
                    _ = try selectWiFiNetwork(
                        ssid: spec.underlayHomeSsid,
                        passphrase: spec.underlayHomePassphrase,
                        timeout: associationTimeout
                    )
                } catch {
                    XCTFail("Underlay cleanup could not restore the original Wi-Fi")
                }
            }
        }

        emit("NVPN_IOS_UNDERLAY_SWITCH_1_REQUESTED_MS=\(millisecondsSinceEpoch())")
        wifiNeedsRestoration = true
        let alternateSelectionLowerBound = try selectWiFiNetwork(
            ssid: spec.underlayAlternateSsid,
            passphrase: spec.underlayAlternatePassphrase,
            timeout: associationTimeout
        )
        guard let alternatePathLowerBound = pathMonitor.waitFor(
            required: .wifi,
            excluded: nil,
            timeout: associationTimeout
        ) else {
            throw gateError("Alternate Wi-Fi underlay never became available")
        }
        let alternateAvailableLowerBound = min(
            alternateSelectionLowerBound,
            alternatePathLowerBound
        )
        emit("NVPN_IOS_UNDERLAY_SWITCH_1_AVAILABLE_MS=\(millisecondsSinceEpoch())")
        let alternatePayloadUptime = try NostrVpnReleaseNetworkProbe.requireUDPEcho(
            host: spec.udpHost,
            port: spec.udpPort,
            label: "\(spec.caseName)-alternate-wifi-first-payload",
            timeout: 5
        )
        try assertPayloadRecovery(
            cycle: 1,
            availabilityLowerBoundUptime: alternateAvailableLowerBound,
            payloadUptime: alternatePayloadUptime
        )
        try waitForSourceIP(
            spec.sourceIpUrl,
            expected: spec.expectedExitSourceIp,
            timeout: 8
        )
        app.activate()
        guard waitForApplicationState(.runningForeground, timeout: 10),
              waitForVPNState(on: true, timeout: 8)
        else {
            throw gateError("Release app/VPN did not foreground on alternate Wi-Fi")
        }
        try proveExit(spec, label: "alternate-wifi")
        emit("NVPN_IOS_UNDERLAY_SWITCH_1_VERIFIED_MS=\(millisecondsSinceEpoch())")

        emit("NVPN_IOS_UNDERLAY_SWITCH_2_REQUESTED_MS=\(millisecondsSinceEpoch())")
        let homeSelectionLowerBound = try selectWiFiNetwork(
            ssid: spec.underlayHomeSsid,
            passphrase: spec.underlayHomePassphrase,
            timeout: associationTimeout
        )
        guard let homePathLowerBound = pathMonitor.waitFor(
            required: .wifi,
            excluded: nil,
            timeout: associationTimeout
        ) else {
            throw gateError("Original Wi-Fi underlay did not return")
        }
        wifiNeedsRestoration = false
        let homeAvailableLowerBound = min(
            homeSelectionLowerBound,
            homePathLowerBound
        )
        emit("NVPN_IOS_UNDERLAY_SWITCH_2_AVAILABLE_MS=\(millisecondsSinceEpoch())")
        let wifiPayloadUptime = try NostrVpnReleaseNetworkProbe.requireUDPEcho(
            host: spec.udpHost,
            port: spec.udpPort,
            label: "\(spec.caseName)-wifi-restored-first-payload",
            timeout: 5
        )
        try assertPayloadRecovery(
            cycle: 2,
            availabilityLowerBoundUptime: homeAvailableLowerBound,
            payloadUptime: wifiPayloadUptime
        )
        try waitForSourceIP(
            spec.sourceIpUrl,
            expected: spec.expectedExitSourceIp,
            timeout: 8
        )
        app.activate()
        guard waitForApplicationState(.runningForeground, timeout: 10),
              waitForVPNState(on: true, timeout: 8)
        else {
            throw gateError("Release app/VPN did not foreground after Wi-Fi restoration")
        }
        try proveExit(spec, label: "wifi-restored")
        emit("NVPN_IOS_UNDERLAY_SWITCH_2_VERIFIED_MS=\(millisecondsSinceEpoch())")
    }

    func waitForPhysicalPath(
        required: NWInterface.InterfaceType,
        excluded: NWInterface.InterfaceType?,
        timeout: TimeInterval
    ) -> TimeInterval? {
        let monitor = NostrVpnReleasePhysicalPathMonitor()
        defer { monitor.cancel() }
        return monitor.waitFor(
            required: required,
            excluded: excluded,
            timeout: timeout
        )
    }

    func assertPayloadRecovery(
        cycle: Int,
        availabilityLowerBoundUptime: TimeInterval,
        payloadUptime: TimeInterval
    ) throws {
        guard payloadUptime >= availabilityLowerBoundUptime else {
            throw gateError("Underlay payload preceded its conservative availability bound")
        }
        let recoveryMilliseconds = Int64(
            ((payloadUptime - availabilityLowerBoundUptime) * 1_000).rounded(.up)
        )
        guard recoveryMilliseconds <= 4_000 else {
            throw gateError(
                "Underlay switch \(cycle) first payload took "
                    + "\(recoveryMilliseconds)ms after path availability"
            )
        }
        emit(
            "NVPN_IOS_UNDERLAY_SWITCH_\(cycle)_PAYLOAD_RECOVERY_MS="
                + "\(recoveryMilliseconds)"
        )
    }

    func selectWiFiNetwork(
        ssid: String,
        passphrase: String,
        timeout: TimeInterval
    ) throws -> TimeInterval {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        guard waitForApplicationState(settings, .runningForeground, timeout: 8) else {
            throw gateError("Settings did not foreground for the Wi-Fi transition")
        }
        try openWiFiSettings(settings)
        let cell = settings.cells.containing(
            .staticText,
            identifier: ssid
        ).firstMatch
        for _ in 0..<12 {
            if cell.isHittable {
                break
            }
            settings.swipeUp()
        }
        guard cell.waitForExistence(timeout: 8), cell.isHittable else {
            throw gateError("Required physical Wi-Fi network was unavailable")
        }
        cell.tap()

        let password = settings.secureTextFields.firstMatch
        if password.waitForExistence(timeout: 2) {
            guard !passphrase.isEmpty else {
                throw gateError("Required physical Wi-Fi needs a private passphrase")
            }
            password.tap()
            password.typeText(passphrase)
            let join = settings.buttons["Join"]
            guard join.waitForExistence(timeout: 3), join.isEnabled else {
                throw gateError("Settings did not enable the Wi-Fi Join action")
            }
            join.tap()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastUnselectedCheckStarted = ProcessInfo.processInfo.systemUptime
        repeat {
            let checkStarted = ProcessInfo.processInfo.systemUptime
            if wifiCellIsSelected(cell) {
                return lastUnselectedCheckStarted
            }
            lastUnselectedCheckStarted = checkStarted
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw gateError("Settings never confirmed the requested physical Wi-Fi")
    }

    func selectedWiFiSSID() throws -> String {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        guard waitForApplicationState(settings, .runningForeground, timeout: 8) else {
            throw gateError("Settings did not foreground for home Wi-Fi readback")
        }
        try openWiFiSettings(settings)
        for cell in settings.cells.allElementsBoundByIndex where wifiCellIsSelected(cell) {
            let labels = cell.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .filter { !$0.isEmpty }
            if let ssid = labels.first {
                return ssid
            }
        }
        throw gateError("Settings did not expose the already-selected home Wi-Fi")
    }

    func openWiFiSettings(_ settings: XCUIApplication) throws {
        if settings.navigationBars["Wi-Fi"].exists {
            return
        }
        for _ in 0..<5 {
            let row = settings.cells.containing(
                .staticText,
                identifier: "Wi-Fi"
            ).firstMatch
            if row.waitForExistence(timeout: 1), row.isHittable {
                row.tap()
                guard settings.navigationBars["Wi-Fi"].waitForExistence(timeout: 5) else {
                    throw gateError("Settings did not open the Wi-Fi page")
                }
                return
            }
            let back = settings.navigationBars.buttons.element(boundBy: 0)
            if back.exists, back.isHittable {
                back.tap()
            }
        }
        throw gateError("Settings Wi-Fi page was unavailable")
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
}
