import Foundation
import XCTest

/// Black-box join coverage for the exact Release app installed on a phone.
///
/// Values are passed to the XCTest runner, never to the application. Every
/// mutation and assertion below goes through the shipped accessibility tree.
/// The shell orchestrator watches stderr markers so Android can perform the
/// other half of a cross-device operation while this runner waits.
final class NostrVpnReleaseJoinUITests: XCTestCase {
    private let app = XCUIApplication()
    private let environment = ProcessInfo.processInfo.environment
    private let qrContentWidthMinimumBasisPoints = 9_800
    private let qrContentWidthMaximumBasisPoints = 10_000

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCTAssertEqual(environment["NVPN_RELEASE_JOIN_BLACKBOX"], "1")
        XCTAssertTrue(app.launchArguments.isEmpty, "Release join gate must not pass app arguments")
        XCTAssertTrue(app.launchEnvironment.isEmpty, "Release join gate must not pass app environment")
        app.launch()
        dismissSystemPromptsIfPresent()
    }

    func testCreateAdminNetworkAndReportPublicValues() throws {
        try createNetwork(named: required("NVPN_RELEASE_JOIN_NETWORK_NAME"))
        openLinkDevice()
        let admin = try publicValue("admin-device-id-value", kind: .npub)
        let network = try publicValue("admin-network-id-value", kind: .network)
        emit("NVPN_RELEASE_JOIN_ADMIN_ID=\(admin)")
        emit("NVPN_RELEASE_JOIN_NETWORK_ID=\(network)")
        emit("NVPN_RELEASE_JOIN_ADMIN_READY=1")
    }

    func testShowPhysicalJoinQrAndRequireRosterCompletion() throws {
        let expectedAdmin = try requiredNpub("NVPN_RELEASE_JOIN_ADMIN_ID")
        openJoinNetwork()
        expandManualJoinIfNeeded()
        let joiner = try publicValue("joiner-device-id-value", kind: .npub)
        emit("NVPN_RELEASE_JOIN_JOINER_ID=\(joiner)")

        let qr = element("join-request-qr-content")
        XCTAssertTrue(qr.waitForExistence(timeout: 10), "Shipped full-width join QR was not visible")
        let initialQrWidthBasisPoints = assertQrIsFullWidth(qr)
        emit("NVPN_RELEASE_JOIN_QR_READY=1")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(
            qr.waitForExistence(timeout: 5),
            "Pending join QR disappeared across a real background/foreground cycle"
        )
        let foregroundQrWidthBasisPoints = assertQrIsFullWidth(qr)
        emit(
            "NVPN_RELEASE_JOIN_QR_CONTENT_WIDTH_BPS="
                + "\(min(initialQrWidthBasisPoints, foregroundQrWidthBasisPoints))"
        )
        emit("NVPN_RELEASE_JOIN_LIFECYCLE_READY=1")

        XCTAssertTrue(
            waitForRosterBackedPendingQrDismissal(
                qr,
                expectedParticipant: expectedAdmin
            ),
            "Join QR disappeared before the exact admin roster was visible"
        )
        requireAcceptedRoster(
            expectedAdmin,
            relaunch: true,
            failureMessage: "QR join did not retain the admin's signed roster"
        )
        emit("NVPN_RELEASE_JOIN_QR_RELAUNCH_DURABLE=\(expectedAdmin)")
        emit("NVPN_RELEASE_JOIN_JOINER_LEFT_QR=1")
        emit("NVPN_RELEASE_JOIN_ROSTER_PARTICIPANT=\(expectedAdmin)")
    }

    func testScanPhysicalJoinQrAndRequireAdminRosterProgress() throws {
        let expectedJoiner = try requiredNpub("NVPN_RELEASE_JOIN_JOINER_ID")
        openLinkDevice()
        let before = rosterParticipantCount()
        XCTAssertEqual(before, 0, "New admin network already contained a roster participant")
        let scan = element("join-request-scan-open")
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        allowCameraAccessIfNeeded()
        XCTAssertTrue(element("qr-scanner-camera").waitForExistence(timeout: 10))
        emit("NVPN_RELEASE_JOIN_SCANNER_READY=1")

        let confirm = element("join-request-confirm-add")
        XCTAssertTrue(
            confirm.waitForExistence(timeout: cameraTimeout),
            "Camera did not decode the other phone's displayed join QR"
        )
        emit("NVPN_RELEASE_JOIN_QR_DECODED=1")
        Thread.sleep(forTimeInterval: 3)
        emit("NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=\(millisecondsSinceEpoch())")
        confirm.tap()
        openDevicesTab()
        XCTAssertTrue(
            element("roster-participant-accepted-\(expectedJoiner)")
                .waitForExistence(timeout: deliveryTimeout),
            "Admin roster did not show the scanned joining identity"
        )
        XCTAssertGreaterThanOrEqual(rosterParticipantCount(), before + 1)
        emit("NVPN_RELEASE_JOIN_ADMIN_ACCEPTED=\(expectedJoiner)")
    }

    func testManualJoinAndRequireRosterCompletion() throws {
        let admin = try requiredNpub("NVPN_RELEASE_JOIN_ADMIN_ID")
        let network = try required("NVPN_RELEASE_JOIN_NETWORK_ID")
        openJoinNetwork()
        expandManualJoinIfNeeded()
        let joiner = try publicValue("joiner-device-id-value", kind: .npub)
        emit("NVPN_RELEASE_JOIN_JOINER_ID=\(joiner)")

        replaceText(element("manual-join-admin-id"), with: admin)
        replaceText(element("manual-join-network-id"), with: network)
        let submit = scrollTo("manual-join-submit")
        submit.tap()
        dismissSystemPromptsIfPresent()
        emit("NVPN_RELEASE_JOIN_MANUAL_SUBMITTED=1")

        XCTAssertTrue(
            waitUntil(timeout: deliveryTimeout) {
                self.app.tabBars.buttons["Devices"].exists
            },
            "Manual join did not leave the first-run join screen"
        )
        openDevicesTab()
        requireAcceptedRoster(
            admin,
            relaunch: true,
            failureMessage: "Manual join did not receive and retain the admin's signed roster"
        )
        emit("NVPN_RELEASE_JOIN_MANUAL_COMPLETE=\(admin)")
        emit("NVPN_RELEASE_JOIN_RELAUNCH_DURABLE=\(admin)")
    }

    func testManualAdminAddRequiresRosterProgress() throws {
        let joiner = try requiredNpub("NVPN_RELEASE_JOIN_JOINER_ID")
        openLinkDevice()
        let before = rosterParticipantCount()
        XCTAssertEqual(before, 0, "New admin network already contained a roster participant")
        replaceText(scrollTo("manual-admin-joiner-id"), with: joiner)
        let alias = element("manual-admin-alias")
        if alias.exists {
            replaceText(alias, with: "Release gate phone")
        }
        emit("NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=\(millisecondsSinceEpoch())")
        scrollTo("manual-admin-submit").tap()
        openDevicesTab()
        XCTAssertTrue(
            element("roster-participant-accepted-\(joiner)")
                .waitForExistence(timeout: deliveryTimeout),
            "Manual admin add did not produce an exact roster row"
        )
        XCTAssertGreaterThanOrEqual(rosterParticipantCount(), before + 1)
        requireAcceptedRoster(
            joiner,
            relaunch: true,
            failureMessage: "Manual admin add did not retain the joining device's signed roster"
        )
        emit("NVPN_RELEASE_JOIN_ADMIN_RELAUNCH_DURABLE=\(joiner)")
        emit("NVPN_RELEASE_JOIN_ADMIN_ACCEPTED=\(joiner)")
    }

    func testReportJoinerPublicIdentity() throws {
        openJoinNetwork()
        expandManualJoinIfNeeded()
        let joiner = try publicValue("joiner-device-id-value", kind: .npub)
        emit("NVPN_RELEASE_JOIN_JOINER_ID=\(joiner)")
    }

    private enum PublicValueKind {
        case npub
        case network
    }

    private var deliveryTimeout: TimeInterval {
        boundedTimeout("NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS", maximum: 15)
    }

    private var cameraTimeout: TimeInterval {
        boundedTimeout("NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS", maximum: 30)
    }

    private func boundedTimeout(_ name: String, maximum: TimeInterval) -> TimeInterval {
        guard let raw = environment[name],
              let value = TimeInterval(raw),
              value > 0
        else {
            return maximum
        }
        return min(value, maximum)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openDevicesTab() {
        let devices = app.tabBars.buttons["Devices"]
        if devices.waitForExistence(timeout: 3) {
            devices.tap()
        }
    }

    private func assertQrIsFullWidth(_ qr: XCUIElement) -> Int {
        let copyRequest = app.buttons["Copy Request"]
        let share = app.buttons["Share"]
        XCTAssertTrue(
            copyRequest.waitForExistence(timeout: 5),
            "Copy Request content boundary was not visible"
        )
        XCTAssertTrue(
            share.waitForExistence(timeout: 5),
            "Share content boundary was not visible"
        )
        let contentLeft = min(copyRequest.frame.minX, share.frame.minX)
        let contentRight = max(copyRequest.frame.maxX, share.frame.maxX)
        let contentWidth = contentRight - contentLeft
        XCTAssertGreaterThan(contentWidth, 0)
        guard contentWidth > 0 else {
            return 0
        }
        let ratioBasisPoints = Int((qr.frame.width / contentWidth * 10_000).rounded(.down))
        XCTAssertGreaterThanOrEqual(
            ratioBasisPoints,
            qrContentWidthMinimumBasisPoints,
            "Join QR did not occupy the mobile content width"
        )
        XCTAssertLessThanOrEqual(
            ratioBasisPoints,
            qrContentWidthMaximumBasisPoints,
            "Join QR exceeded its mobile content width"
        )
        return ratioBasisPoints
    }

    private func openLinkDevice() {
        openDevicesTab()
        let link = element("link-device-open")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Link device was not available")
        link.tap()
        XCTAssertTrue(element("admin-device-id-value").waitForExistence(timeout: 10))
    }

    private func createNetwork(named name: String) throws {
        if !element("network-setup-create").waitForExistence(timeout: 3) {
            let switcher = element("network-switcher-open")
            XCTAssertTrue(switcher.waitForExistence(timeout: 5))
            switcher.tap()
            let add = element("add-network-open")
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
        }
        let create = element("network-setup-create")
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        let nameField = element("network-create-name")
        XCTAssertTrue(
            ShippedUIInteraction.reveal(nameField, byTapping: create),
            "Shipped Create Network control did not reveal the network-name field"
        )
        dismissSystemPromptsIfPresent()
        replaceText(element("network-create-name"), with: name)
        scrollTo("network-create-submit").tap()
        XCTAssertTrue(app.tabBars.buttons["Devices"].waitForExistence(timeout: 10))
    }

    private func openJoinNetwork() {
        if !element("network-setup-join").waitForExistence(timeout: 3) {
            let switcher = element("network-switcher-open")
            XCTAssertTrue(switcher.waitForExistence(timeout: 5))
            switcher.tap()
            let add = element("add-network-open")
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
        }
        let join = element("network-setup-join")
        XCTAssertTrue(join.waitForExistence(timeout: 5))
        join.tap()
    }

    private func expandManualJoinIfNeeded() {
        if !element("joiner-device-id-value").waitForExistence(timeout: 2) {
            let manual = scrollTo("manual-join-expand")
            manual.tap()
        }
        XCTAssertTrue(element("joiner-device-id-value").waitForExistence(timeout: 5))
    }

    private func scrollTo(_ identifier: String) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<12 where !target.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            target.waitForExistence(timeout: 5) && target.isHittable,
            "\(identifier) was not visible"
        )
        return target
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        let retained = ShippedUIInteraction.replaceText(field, with: value, in: app)
        XCTAssertTrue(
            retained,
            "Shipped text control did not retain the exact supplied value"
        )
        if retained {
            field.typeKey(.return, modifierFlags: [])
        }
    }

    private func publicValue(
        _ identifier: String,
        kind: PublicValueKind
    ) throws -> String {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let candidates = [target.label, target.value as? String ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let value = candidates.first(where: { candidate in
            switch kind {
            case .npub:
                return isNpub(candidate)
            case .network:
                return !candidate.isEmpty && candidate != "-"
            }
        }) else {
            throw GateError.invalidPublicValue(identifier)
        }
        return value.replacingOccurrences(of: "-", with: kind == .network ? "" : "-")
    }

    private func required(_ name: String) throws -> String {
        let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw GateError.missingEnvironment(name)
        }
        return value
    }

    private func requiredNpub(_ name: String) throws -> String {
        let value = try required(name)
        guard isNpub(value) else {
            throw GateError.invalidPublicValue(name)
        }
        return value
    }

    private func isNpub(_ value: String) -> Bool {
        value.count == 63
            && value.hasPrefix("npub1")
            && value.dropFirst(5).allSatisfy {
                "qpzry9x8gf2tvdw0s3jn54khce6mua7l".contains($0)
            }
    }

    private func rosterParticipantCount() -> Int {
        app.descendants(matching: .any)
            .allElementsBoundByIndex
            .filter { $0.identifier.hasPrefix("roster-participant-") }
            .count
    }

    private func requireAcceptedRoster(
        _ participant: String,
        relaunch: Bool,
        failureMessage: String
    ) {
        let identifier = "roster-participant-accepted-\(participant)"
        XCTAssertTrue(
            element(identifier).waitForExistence(timeout: deliveryTimeout),
            failureMessage
        )
        guard relaunch else {
            return
        }
        app.terminate()
        app.launch()
        dismissSystemPromptsIfPresent()
        openDevicesTab()
        XCTAssertTrue(
            element(identifier).waitForExistence(timeout: deliveryTimeout),
            "\(failureMessage) after a real app relaunch"
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForRosterBackedPendingQrDismissal(
        _ qr: XCUIElement,
        expectedParticipant: String
    ) -> Bool {
        let deadline = Date().addingTimeInterval(deliveryTimeout)
        repeat {
            if qr.exists {
                emit("NVPN_RELEASE_JOIN_PENDING_QR_VISIBLE_MS=\(millisecondsSinceEpoch())")
            } else {
                let devicesTab = app.tabBars.buttons["Devices"]
                guard devicesTab.exists else {
                    return false
                }
                devicesTab.tap()
                guard element("roster-participant-accepted-\(expectedParticipant)").exists else {
                    return false
                }
                emit(
                    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS="
                        + "\(millisecondsSinceEpoch())"
                )
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    private func allowCameraAccessIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }

    private func dismissSystemPromptsIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(5)
        var clearSince: Date?
        repeat {
            var handledPrompt = false
            let allow = springboard.alerts.buttons["Allow"]
            if allow.exists, allow.isHittable {
                allow.tap()
                handledPrompt = true
            }
            let disclosure = app.navigationBars["VPN Data Use"].buttons["Continue"]
            if disclosure.exists, disclosure.isHittable {
                disclosure.tap()
                handledPrompt = true
            }
            if handledPrompt {
                clearSince = nil
            } else if let clearSince {
                if Date().timeIntervalSince(clearSince) >= 0.5 {
                    return
                }
            } else {
                clearSince = Date()
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
    }

    private func emit(_ marker: String) {
        let data = Data("NVPN_RELEASE_JOIN_MARKER \(marker)\n".utf8)
        FileHandle.standardError.write(data)
    }

    private func millisecondsSinceEpoch() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private enum GateError: LocalizedError {
        case missingEnvironment(String)
        case invalidPublicValue(String)

        var errorDescription: String? {
            switch self {
            case .missingEnvironment(let name):
                return "Release join gate did not provide \(name)"
            case .invalidPublicValue(let name):
                return "Release UI did not expose a valid public value for \(name)"
            }
        }
    }
}
