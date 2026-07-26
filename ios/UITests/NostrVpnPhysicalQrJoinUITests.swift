import Foundation
import XCTest

/// Physical-only coverage for the exact camera paths shipped to users.
///
/// The shell gate displays the other phone's QR and a human only aims the
/// devices. This test never receives, pastes, or launches with a QR payload.
final class NostrVpnPhysicalQrJoinUITests: XCTestCase {
    private enum GateError: LocalizedError {
        case missingEnvironment(String)

        var errorDescription: String? {
            switch self {
            case .missingEnvironment(let name):
                return "The physical gate did not provide \(name)."
            }
        }
    }

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        PhysicalGateMarker.reset()
    }

    func testPhysicalAutomationPermissionIsReady() {
        emit("NVPN_XCUITEST_AUTOMATION_READY=1")
    }

    func testPhysicalEnvironmentBridgeIsReady() {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(environment["NVPN_XCUITEST_PHYSICAL_JOIN_GATE"], "1")
        XCTAssertEqual(
            environment["NVPN_XCUITEST_MANUAL_ADMIN_DEVICE_ID"],
            "xcuitest-bridge-admin"
        )
        XCTAssertEqual(
            environment["NVPN_XCUITEST_MANUAL_NETWORK_ID"],
            "xcuitest-bridge-network"
        )
        XCTAssertEqual(
            environment["NVPN_XCUITEST_MANUAL_JOINER_DEVICE_ID"],
            "xcuitest-bridge-joiner"
        )
        emit("NVPN_XCUITEST_ENVIRONMENT_BRIDGE_READY=1")
    }

    func testApproveAndroidJoinRequestThroughPhysicalCamera() {
        app.launch()
        acknowledgeVpnPromptsIfPresent()
        openDevicesTab()

        let linkDevice = element("link-device-open")
        XCTAssertTrue(linkDevice.waitForExistence(timeout: 10))
        linkDevice.tap()

        let scan = element("join-request-scan-open")
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        allowCameraAccessIfNeeded()

        XCTAssertTrue(element("qr-scanner-camera").waitForExistence(timeout: 10))
        emit("NVPN_QR_SCANNER_READY=1")

        let confirm = element("join-request-confirm-add")
        XCTAssertTrue(
            confirm.waitForExistence(timeout: PhysicalGateTimeouts.camera),
            "The physical camera did not decode a valid joining-device request."
        )
        emit("NVPN_QR_APPROVAL_SUBMITTED_MS=\(millisecondsSinceEpoch())")
        confirm.tap()
    }

    func testJoinAndroidAdminThroughManualEntry() throws {
        let environment = ProcessInfo.processInfo.environment
        let adminDeviceId = try requiredEnvironment(
            "NVPN_XCUITEST_MANUAL_ADMIN_DEVICE_ID",
            environment: environment
        )
        let networkId = try requiredEnvironment(
            "NVPN_XCUITEST_MANUAL_NETWORK_ID",
            environment: environment
        )

        app.launch()
        acknowledgeVpnPromptsIfPresent()
        openJoinNetworkPage()

        let manual = element("manual-join-expand")
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        replaceText(element("manual-join-admin-id"), with: adminDeviceId)
        replaceText(element("manual-join-network-id"), with: networkId)

        let submit = scrollToElement("manual-join-submit")
        emit("NVPN_MANUAL_JOINER_SUBMITTED_MS=\(millisecondsSinceEpoch())")
        submit.tap()
        acknowledgeVpnPromptsIfPresent()
        XCTAssertTrue(app.tabBars.buttons["Devices"].waitForExistence(timeout: 20))
    }

    func testAddAndroidJoinerThroughManualEntry() throws {
        let deviceId = try requiredEnvironment(
            "NVPN_XCUITEST_MANUAL_JOINER_DEVICE_ID",
            environment: ProcessInfo.processInfo.environment
        )

        app.launch()
        acknowledgeVpnPromptsIfPresent()
        openDevicesTab()
        let linkDevice = element("link-device-open")
        XCTAssertTrue(linkDevice.waitForExistence(timeout: 10))
        linkDevice.tap()

        let field = scrollToElement("manual-admin-joiner-id")
        replaceText(field, with: deviceId)
        let submit = scrollToElement("manual-admin-submit")
        emit("NVPN_MANUAL_ADMIN_SUBMITTED_MS=\(millisecondsSinceEpoch())")
        submit.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openDevicesTab() {
        let devicesTab = app.tabBars.buttons["Devices"]
        if devicesTab.waitForExistence(timeout: 2) {
            devicesTab.tap()
        }
    }

    private func openJoinNetworkPage() {
        let join = element("network-setup-join")
        if !join.waitForExistence(timeout: 3) {
            let switcher = element("network-switcher-open")
            XCTAssertTrue(
                switcher.waitForExistence(timeout: 5),
                "The shipped network switcher was not visible."
            )
            switcher.tap()
            let addNetwork = element("add-network-open")
            XCTAssertTrue(
                addNetwork.waitForExistence(timeout: 5),
                "The shipped Add network action was not visible."
            )
            addNetwork.tap()
        }
        scrollToElement("network-setup-join").tap()
    }

    private func scrollToElement(_ identifier: String) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<10 where !target.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "\(identifier) was not visible")
        return target
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(value)
        field.typeKey(.return, modifierFlags: [])
    }

    private func requiredEnvironment(
        _ name: String,
        environment: [String: String]
    ) throws -> String {
        let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            throw GateError.missingEnvironment(name)
        }
        return value
    }

    private func allowCameraAccessIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }

    private func acknowledgeVpnPromptsIfPresent() {
        let disclosure = app.buttons["Continue"]
        if disclosure.waitForExistence(timeout: 3) {
            disclosure.tap()
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }

    private func millisecondsSinceEpoch() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func emit(_ marker: String) {
        PhysicalGateMarker.emit(marker)
    }
}
