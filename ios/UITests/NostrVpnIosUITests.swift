import Foundation
import XCTest

final class NostrVpnIosUITests: XCTestCase {
    private struct ExitDnsPacketProbeSpec: Decodable {
        let caseName: String
        let mode: String
        let provider: String
        let customUrl: String
        let bootstrapIps: String
        let throughExitServers: String
        let createNetwork: Bool
    }

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        PhysicalGateMarker.reset()
    }

    func testJoinAdvertisingUsesTheShippedUiAndSurvivesBackgrounding() {
        app.launch()
        acknowledgeVpnPromptsIfPresent()
        openJoinNetworkPage()

        let qr = app.descendants(matching: .any)["join-request-qr-content"]
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(qr.frame.width, app.frame.width * 0.75)

        let advertise = app.buttons["Advertise nearby"]
        XCTAssertTrue(advertise.waitForExistence(timeout: 5))
        advertise.tap()
        acknowledgeVpnPromptsIfPresent()

        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Advertising")
            ).firstMatch.waitForExistence(timeout: 15)
        )

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()

        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Advertising")
            ).firstMatch.waitForExistence(timeout: 5)
        )

    }

    func testNearbyDiscoveryUsesTheShippedUiAndSurvivesBackgrounding() {
        app.launchArguments = [
            "--nvpn-debug-add-network", "Nearby lifecycle test",
            "--nvpn-screenshot-tab", "devices",
        ]
        app.launch()
        acknowledgeVpnPromptsIfPresent()

        let openLinkDevice = element("link-device-open")
        XCTAssertTrue(openLinkDevice.waitForExistence(timeout: 5))
        openLinkDevice.tap()

        let findNearby = app.buttons["Find nearby"]
        XCTAssertTrue(findNearby.waitForExistence(timeout: 5))
        findNearby.tap()

        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Finding nearby")
            ).firstMatch.waitForExistence(timeout: 5)
        )

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()

        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Finding nearby")
            ).firstMatch.waitForExistence(timeout: 5)
        )
    }

    func testExitDnsSettingsUseShippedControlsAndValidateRequiredFields() {
        app.launchArguments = [
            "--nvpn-debug-add-network", "DNS UI test",
            "--nvpn-screenshot-tab", "internet",
        ]
        app.launch()
        acknowledgeVpnPromptsIfPresent()

        let sourcePicker = scrollToElement("internet-source-picker")
        sourcePicker.tap()
        tapMenuOption(identifier: "internet-source-wireguard", label: "WireGuard VPN")
        acknowledgeVpnPromptsIfPresent()

        selectMenu(
            picker: "exit-dns-mode-picker",
            option: "exit-dns-mode-automatic",
            label: "Automatic (recommended)"
        )
        saveExitDnsAndRelaunch()
        assertPicker("exit-dns-mode-picker", contains: "Automatic")

        selectMenu(
            picker: "exit-dns-mode-picker",
            option: "exit-dns-mode-encrypted",
            label: "Encrypted DNS"
        )
        selectMenu(
            picker: "exit-dns-provider-picker",
            option: "exit-dns-provider-cloudflare",
            label: "Cloudflare"
        )
        saveExitDnsAndRelaunch()
        assertPicker("exit-dns-mode-picker", contains: "Encrypted DNS")
        assertPicker("exit-dns-provider-picker", contains: "Cloudflare")

        selectMenu(
            picker: "exit-dns-provider-picker",
            option: "exit-dns-provider-quad9",
            label: "Quad9"
        )
        saveExitDnsAndRelaunch()
        assertPicker("exit-dns-mode-picker", contains: "Encrypted DNS")
        assertPicker("exit-dns-provider-picker", contains: "Quad9")

        selectMenu(
            picker: "exit-dns-mode-picker",
            option: "exit-dns-mode-through-exit",
            label: "DNS through exit"
        )

        let throughExitServers = scrollToElement("exit-dns-through-exit-servers")
        clearText(throughExitServers)
        dismissKeyboardIfPresent()
        let validation = scrollToElement("exit-dns-validation-error")
        XCTAssertEqual(validation.label, "Enter at least one DNS server IP.")
        XCTAssertFalse(element("exit-dns-save").isEnabled)
        throughExitServers.tap()
        throughExitServers.typeText("9.9.9.9")
        dismissKeyboardIfPresent()
        saveExitDnsAndRelaunch()
        assertPicker("exit-dns-mode-picker", contains: "DNS through exit")
        XCTAssertEqual(
            scrollToElement("exit-dns-through-exit-servers").value as? String,
            "9.9.9.9"
        )

        selectMenu(
            picker: "exit-dns-mode-picker",
            option: "exit-dns-mode-encrypted",
            label: "Encrypted DNS"
        )
        selectMenu(
            picker: "exit-dns-provider-picker",
            option: "exit-dns-provider-custom",
            label: "Custom DoH"
        )

        let customUrl = scrollToElement("exit-dns-custom-url")
        let bootstrapIps = scrollToElement("exit-dns-custom-bootstrap-ips")
        clearText(customUrl)
        clearText(bootstrapIps)
        dismissKeyboardIfPresent()
        XCTAssertEqual(
            scrollToElement("exit-dns-validation-error").label,
            "Enter an HTTPS DoH URL."
        )
        customUrl.tap()
        customUrl.typeText("https://resolver.example/dns-query")
        dismissKeyboardIfPresent()
        XCTAssertEqual(
            scrollToElement("exit-dns-validation-error").label,
            "Enter at least one bootstrap IP."
        )
        bootstrapIps.tap()
        bootstrapIps.typeText("192.0.2.53")
        dismissKeyboardIfPresent()

        saveExitDnsAndRelaunch()
        assertPicker("exit-dns-mode-picker", contains: "Encrypted DNS")
        assertPicker("exit-dns-provider-picker", contains: "Custom DoH")
        XCTAssertEqual(
            scrollToElement("exit-dns-custom-url").value as? String,
            "https://resolver.example/dns-query"
        )
        XCTAssertEqual(
            scrollToElement("exit-dns-custom-bootstrap-ips").value as? String,
            "192.0.2.53"
        )
        XCTAssertFalse(element("exit-dns-validation-error").exists)
        emit("NVPN_EXIT_DNS_UI_CONTROLS_PASSED=1")
    }

    func testConfigureExitDnsForPhysicalPacketProbe() throws {
        let spec = try exitDnsPacketProbeSpec()
        app.launchArguments = ["--nvpn-screenshot-tab", "internet"]
        if spec.createNetwork {
            app.launchArguments = [
                "--nvpn-debug-add-network", "DNS packet gate",
            ] + app.launchArguments
        }
        app.launch()
        acknowledgeVpnPromptsIfPresent()

        let sourcePicker = scrollToElement("internet-source-picker")
        sourcePicker.tap()
        tapMenuOption(identifier: "internet-source-wireguard", label: "WireGuard VPN")
        acknowledgeVpnPromptsIfPresent()

        // Reset every persisted field through the shipped controls so the
        // following packet probe cannot inherit an inactive value from a
        // previous DNS case.
        selectMenu(
            picker: "exit-dns-mode-picker",
            option: "exit-dns-mode-encrypted",
            label: "Encrypted DNS"
        )
        selectMenu(
            picker: "exit-dns-provider-picker",
            option: "exit-dns-provider-custom",
            label: "Custom DoH"
        )
        clearText(scrollToElement("exit-dns-custom-url"))
        clearText(scrollToElement("exit-dns-custom-bootstrap-ips"))
        dismissKeyboardIfPresent()
        selectMenu(
            picker: "exit-dns-mode-picker",
            option: "exit-dns-mode-through-exit",
            label: "DNS through exit"
        )
        clearText(scrollToElement("exit-dns-through-exit-servers"))
        dismissKeyboardIfPresent()

        switch spec.mode {
        case "automatic":
            XCTAssertEqual(spec.provider, "cloudflare")
            XCTAssertTrue(spec.customUrl.isEmpty)
            XCTAssertTrue(spec.bootstrapIps.isEmpty)
            XCTAssertTrue(spec.throughExitServers.isEmpty)
            selectMenu(
                picker: "exit-dns-mode-picker",
                option: "exit-dns-mode-encrypted",
                label: "Encrypted DNS"
            )
            selectMenu(
                picker: "exit-dns-provider-picker",
                option: "exit-dns-provider-cloudflare",
                label: "Cloudflare"
            )
            selectMenu(
                picker: "exit-dns-mode-picker",
                option: "exit-dns-mode-automatic",
                label: "Automatic (recommended)"
            )
        case "encrypted":
            XCTAssertTrue(spec.throughExitServers.isEmpty)
            selectMenu(
                picker: "exit-dns-mode-picker",
                option: "exit-dns-mode-encrypted",
                label: "Encrypted DNS"
            )
            switch spec.provider {
            case "cloudflare":
                XCTAssertTrue(spec.customUrl.isEmpty)
                XCTAssertTrue(spec.bootstrapIps.isEmpty)
                selectMenu(
                    picker: "exit-dns-provider-picker",
                    option: "exit-dns-provider-cloudflare",
                    label: "Cloudflare"
                )
            case "quad9":
                XCTAssertTrue(spec.customUrl.isEmpty)
                XCTAssertTrue(spec.bootstrapIps.isEmpty)
                selectMenu(
                    picker: "exit-dns-provider-picker",
                    option: "exit-dns-provider-quad9",
                    label: "Quad9"
                )
            case "custom":
                XCTAssertFalse(spec.customUrl.isEmpty)
                XCTAssertFalse(spec.bootstrapIps.isEmpty)
                selectMenu(
                    picker: "exit-dns-provider-picker",
                    option: "exit-dns-provider-custom",
                    label: "Custom DoH"
                )
                let customUrl = scrollToElement("exit-dns-custom-url")
                let bootstrapIps = scrollToElement("exit-dns-custom-bootstrap-ips")
                XCTAssertEqual(
                    scrollToElement("exit-dns-validation-error").label,
                    "Enter an HTTPS DoH URL."
                )
                customUrl.tap()
                customUrl.typeText("http://resolver.invalid/dns-query")
                dismissKeyboardIfPresent()
                XCTAssertEqual(
                    scrollToElement("exit-dns-validation-error").label,
                    "DoH URL must use HTTPS."
                )
                clearText(customUrl)
                customUrl.tap()
                customUrl.typeText(spec.customUrl)
                dismissKeyboardIfPresent()
                XCTAssertEqual(
                    scrollToElement("exit-dns-validation-error").label,
                    "Enter at least one bootstrap IP."
                )
                bootstrapIps.tap()
                bootstrapIps.typeText(spec.bootstrapIps)
                dismissKeyboardIfPresent()
            default:
                XCTFail("Unsupported encrypted DNS provider \(spec.provider)")
                return
            }
        case "through_exit":
            XCTAssertEqual(spec.provider, "cloudflare")
            XCTAssertTrue(spec.customUrl.isEmpty)
            XCTAssertTrue(spec.bootstrapIps.isEmpty)
            XCTAssertFalse(spec.throughExitServers.isEmpty)
            selectMenu(
                picker: "exit-dns-mode-picker",
                option: "exit-dns-mode-encrypted",
                label: "Encrypted DNS"
            )
            selectMenu(
                picker: "exit-dns-provider-picker",
                option: "exit-dns-provider-cloudflare",
                label: "Cloudflare"
            )
            selectMenu(
                picker: "exit-dns-mode-picker",
                option: "exit-dns-mode-through-exit",
                label: "DNS through exit"
            )
            XCTAssertEqual(
                scrollToElement("exit-dns-validation-error").label,
                "Enter at least one DNS server IP."
            )
            let throughExitServers = scrollToElement("exit-dns-through-exit-servers")
            throughExitServers.tap()
            throughExitServers.typeText(spec.throughExitServers)
            dismissKeyboardIfPresent()
        default:
            XCTFail("Unsupported Exit DNS mode \(spec.mode)")
            return
        }

        saveExitDnsAndRelaunch()
        switch spec.mode {
        case "automatic":
            assertPicker("exit-dns-mode-picker", contains: "Automatic")
        case "encrypted":
            assertPicker("exit-dns-mode-picker", contains: "Encrypted DNS")
            let providerLabel: String
            switch spec.provider {
            case "cloudflare": providerLabel = "Cloudflare"
            case "quad9": providerLabel = "Quad9"
            case "custom": providerLabel = "Custom DoH"
            default:
                XCTFail("Unsupported persisted DNS provider \(spec.provider)")
                return
            }
            assertPicker("exit-dns-provider-picker", contains: providerLabel)
            if spec.provider == "custom" {
                XCTAssertEqual(
                    scrollToElement("exit-dns-custom-url").value as? String,
                    spec.customUrl
                )
                XCTAssertEqual(
                    scrollToElement("exit-dns-custom-bootstrap-ips").value as? String,
                    spec.bootstrapIps
                )
            }
        case "through_exit":
            assertPicker("exit-dns-mode-picker", contains: "DNS through exit")
            XCTAssertEqual(
                scrollToElement("exit-dns-through-exit-servers").value as? String,
                spec.throughExitServers
            )
        default:
            XCTFail("Unsupported persisted Exit DNS mode \(spec.mode)")
            return
        }
        XCTAssertFalse(element("exit-dns-validation-error").exists)
        emit("NVPN_EXIT_DNS_UI_CONFIG_PERSISTED=\(spec.caseName)")
    }

    func testSelectDirectWhilePhysicalTunnelConnected() throws {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(
            environment["NVPN_XCUITEST_CONNECTED_DIRECT_GATE"],
            "1",
            "The connected Direct test may only run as the physical packet gate."
        )
        app.launchArguments = try connectedDirectLaunchArguments()
        app.launch()
        acknowledgeVpnPromptsIfPresent()

        XCTAssertTrue(
            app.buttons["Turn VPN off"].waitForExistence(timeout: 30),
            "The real packet tunnel did not become connected before the Direct UI transition."
        )

        let internetTab = app.tabBars.buttons["Internet"]
        XCTAssertTrue(internetTab.waitForExistence(timeout: 5))
        internetTab.tap()
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS[c] %@",
                "Waiting for This device selection"
            ),
            object: element("internet-settings-status")
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 30),
            .completed,
            "The real exit/DNS packet probe did not finish before the Direct selection."
        )
        let sourcePicker = scrollToElement("internet-source-picker")
        sourcePicker.tap()
        tapMenuOption(identifier: "internet-source-direct", label: "This device")
        assertPicker("internet-source-picker", contains: "This device")
        XCTAssertTrue(
            app.buttons["Turn VPN off"].exists,
            "Selecting Direct unexpectedly stopped the OS packet tunnel."
        )

        let completion = element("internet-settings-status")
        let verified = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS[c] %@",
                "Direct Internet verified"
            ),
            object: completion
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [verified], timeout: 30),
            .completed,
            "The app did not verify native DNS and Internet after the shipped Direct selection."
        )
        emit("NVPN_CONNECTED_DIRECT_UI_PASSED=1")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openJoinNetworkPage() {
        let join = element("network-setup-join")
        if !join.waitForExistence(timeout: 3) {
            XCTAssertTrue(
                ShippedUIInteraction.openAddNetwork(in: app),
                "The shipped Add network action was not reachable."
            )
        }
        scrollToElement("network-setup-join").tap()
    }

    private func scrollToElement(_ identifier: String) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<8 {
            if target.isHittable {
                break
            }
            if target.exists && target.frame.midY < app.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 2), "\(identifier) was not visible")
        return target
    }

    private func tapMenuOption(identifier: String, label: String) {
        let identified = element(identifier)
        if identified.waitForExistence(timeout: 1) {
            identified.tap()
            return
        }
        let labelled = app.buttons[label]
        XCTAssertTrue(labelled.waitForExistence(timeout: 2), "\(label) menu option was absent")
        labelled.tap()
    }

    private func selectMenu(picker: String, option: String, label: String) {
        scrollToElement(picker).tap()
        tapMenuOption(identifier: option, label: label)
    }

    private func saveExitDnsAndRelaunch() {
        dismissKeyboardIfPresent()
        let save = scrollToElement("exit-dns-save")
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable)
        save.tap()
        let acknowledgement = scrollToElement("exit-dns-save-acknowledgement")
        XCTAssertEqual(acknowledgement.label, "Exit DNS saved")
        relaunchInternet()
    }

    private func relaunchInternet() {
        app.terminate()
        app.launchArguments = ["--nvpn-screenshot-tab", "internet"]
        app.launch()
        acknowledgeVpnPromptsIfPresent()
        XCTAssertTrue(element("internet-source-picker").waitForExistence(timeout: 5))
        assertPicker("internet-source-picker", contains: "WireGuard VPN")
    }

    private func assertPicker(_ identifier: String, contains expected: String) {
        let picker = scrollToElement(identifier)
        let value = picker.value as? String ?? ""
        let summary = "\(picker.label) \(value)"
        XCTAssertTrue(
            summary.localizedCaseInsensitiveContains(expected),
            "\(identifier) selection was \(summary), expected \(expected)"
        )
    }

    private func dismissKeyboardIfPresent() {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let done = app.buttons["exit-dns-keyboard-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 2))
            XCTAssertTrue(done.isHittable)
            done.tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: keyboard
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 2), .completed)
            XCTAssertFalse(keyboard.exists)
        }
    }

    private func clearText(_ field: XCUIElement) {
        for _ in 0..<3 {
            let remaining = enteredText(field)
            if remaining.isEmpty {
                break
            }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            field.typeKey(.rightArrow, modifierFlags: .command)
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: remaining.count)
            )
        }
        XCTAssertEqual(enteredText(field), "")
    }

    private func enteredText(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    private func exitDnsPacketProbeSpec() throws -> ExitDnsPacketProbeSpec {
        let environment = ProcessInfo.processInfo.environment
        let encoded = try XCTUnwrap(
            environment["NVPN_XCUITEST_EXIT_DNS_SPEC_BASE64"],
            "The physical Exit DNS gate did not provide its case spec."
        )
        let data = try XCTUnwrap(
            Data(base64Encoded: encoded),
            "The physical Exit DNS case spec was not valid base64."
        )
        return try JSONDecoder().decode(ExitDnsPacketProbeSpec.self, from: data)
    }

    private func connectedDirectLaunchArguments() throws -> [String] {
        let encoded = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "NVPN_XCUITEST_APP_LAUNCH_ARGS_BASE64"
            ],
            "The physical Direct gate did not provide app launch arguments."
        )
        let data = try XCTUnwrap(
            Data(base64Encoded: encoded),
            "The physical Direct gate launch arguments were not valid base64."
        )
        let arguments = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String],
            "The physical Direct gate launch arguments were not a string array."
        )
        XCTAssertTrue(
            arguments.contains("--nvpn-debug-await-direct-ui-while-connected"),
            "The probe would not wait for the shipped Direct control."
        )
        XCTAssertFalse(
            arguments.contains("--nvpn-debug-switch-to-direct-while-connected"),
            "The obsolete debug Direct mutation must never drive this gate."
        )
        return arguments
    }

    private func acknowledgeVpnPromptsIfPresent() {
        let disclosure = app.buttons["Continue"]
        if disclosure.waitForExistence(timeout: 2) {
            disclosure.tap()
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }

    private func emit(_ marker: String) {
        PhysicalGateMarker.emit(marker)
    }
}
