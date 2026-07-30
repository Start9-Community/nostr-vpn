import Foundation
import XCTest

/// Physical lifecycle coverage driven by XCTest rather than CoreDevice process
/// launches. The app writes its own append-only transition history while this
/// test records the device-level Home, dwell, and activate timeline.
final class NostrVpnLifecycleUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        PhysicalGateMarker.reset()
    }

    func testPhysicalNativeCoreBackgroundForegroundLifecycle() throws {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(
            environment["NVPN_XCUITEST_LIFECYCLE_GATE"],
            "1",
            "The physical lifecycle test may only run through its real-device gate."
        )
        let runId = try requiredEnvironment("NVPN_XCUITEST_RUN_ID", environment: environment)
        let resultName = try requiredEnvironment(
            "NVPN_XCUITEST_LIFECYCLE_RESULT_NAME",
            environment: environment
        )
        let cycles = boundedInteger(
            environment["NVPN_XCUITEST_LIFECYCLE_CYCLES"],
            defaultValue: 3,
            range: 1...5
        )
        let dwellSeconds = boundedInteger(
            environment["NVPN_XCUITEST_LIFECYCLE_BACKGROUND_DWELL_SECS"],
            defaultValue: 3,
            range: 1...30
        )

        app.launchArguments = [
            "--nvpn-debug-lifecycle-result", resultName,
            "--nvpn-debug-lifecycle-run-id", runId,
        ]
        emit("NVPN_IOS_LIFECYCLE_LAUNCH_REQUESTED_MS=\(millisecondsSinceEpoch())")
        app.launch()
        XCTAssertTrue(
            waitForApplicationState(.runningForeground, timeout: 10),
            "The app did not reach the foreground after launch."
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        emit("NVPN_IOS_LIFECYCLE_LAUNCH_FOREGROUND_MS=\(millisecondsSinceEpoch())")

        for cycle in 1...cycles {
            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_HOME_REQUESTED_MS=\(millisecondsSinceEpoch())")
            XCUIDevice.shared.press(.home)
            // XCUIApplication.state can remain .runningForeground after a real
            // Home press on iOS 26. The app-side receipt is authoritative: the
            // host gate requires a background scene event with a closed native
            // core and rejects the run if this press did not background it.
            Thread.sleep(forTimeInterval: 0.25)
            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_BACKGROUND_OBSERVED_MS=\(millisecondsSinceEpoch())")

            Thread.sleep(forTimeInterval: TimeInterval(dwellSeconds))

            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_ACTIVATE_REQUESTED_MS=\(millisecondsSinceEpoch())")
            app.activate()
            // The app-side history likewise proves the active scene event and
            // reopened native core; XCUIApplication.state can lag activation.
            Thread.sleep(forTimeInterval: 0.25)
            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_FOREGROUND_OBSERVED_MS=\(millisecondsSinceEpoch())")
        }

        emit("NVPN_IOS_LIFECYCLE_RESULT_NAME=\(resultName)")
        emit("NVPN_IOS_LIFECYCLE_XCTEST_PASSED_MS=\(millisecondsSinceEpoch())")
    }

    func testPhysicalActiveTunnelBackgroundForegroundLifecycle() throws {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(
            environment["NVPN_XCUITEST_LIFECYCLE_GATE"],
            "1",
            "The active-tunnel lifecycle test may only run through its physical gate."
        )
        let runId = try requiredEnvironment("NVPN_XCUITEST_RUN_ID", environment: environment)
        let resultName = try requiredEnvironment(
            "NVPN_XCUITEST_LIFECYCLE_RESULT_NAME",
            environment: environment
        )
        let cycles = boundedInteger(
            environment["NVPN_XCUITEST_LIFECYCLE_CYCLES"],
            defaultValue: 3,
            range: 1...5
        )
        let dwellSeconds = boundedInteger(
            environment["NVPN_XCUITEST_LIFECYCLE_BACKGROUND_DWELL_SECS"],
            defaultValue: 10,
            range: 1...30
        )
        app.launchArguments = try activeTunnelLaunchArguments(environment: environment)
        XCTAssertTrue(
            app.launchArguments.contains(runId),
            "The app lifecycle receipt is not tied to this XCTest run."
        )

        emit("NVPN_IOS_LIFECYCLE_LAUNCH_REQUESTED_MS=\(millisecondsSinceEpoch())")
        app.launch()
        XCTAssertTrue(
            waitForApplicationState(.runningForeground, timeout: 10),
            "The app did not reach the foreground after launch."
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForStatus("Active VPN ready for lifecycle cycle 1", timeout: 45),
            "The real packet tunnel never became ready for the lifecycle transition."
        )
        emit("NVPN_IOS_LIFECYCLE_LAUNCH_FOREGROUND_MS=\(millisecondsSinceEpoch())")

        for cycle in 1...cycles {
            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_HOME_REQUESTED_MS=\(millisecondsSinceEpoch())")
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 0.25)
            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_BACKGROUND_OBSERVED_MS=\(millisecondsSinceEpoch())")

            Thread.sleep(forTimeInterval: TimeInterval(dwellSeconds))

            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_ACTIVATE_REQUESTED_MS=\(millisecondsSinceEpoch())")
            app.activate()
            XCTAssertTrue(
                waitForApplicationState(.runningForeground, timeout: 10),
                "The app did not return to the foreground with its packet tunnel active."
            )
            Thread.sleep(forTimeInterval: 0.25)
            emit("NVPN_IOS_LIFECYCLE_CYCLE_\(cycle)_FOREGROUND_OBSERVED_MS=\(millisecondsSinceEpoch())")
            let verifiedStatus = cycle < cycles
                ? "Active VPN lifecycle verified \(cycle)/\(cycles); ready for cycle \(cycle + 1)"
                : "Active VPN lifecycle verified \(cycle)/\(cycles)"
            XCTAssertTrue(
                waitForStatus(verifiedStatus, timeout: 45),
                "The app did not re-prove tunnel, DNS, and HTTPS after lifecycle cycle \(cycle)."
            )
        }

        driveConnectedDirectIfRequested()
        XCTAssertTrue(
            waitForStatus("VPN lifecycle release probe finished", timeout: 45),
            "The app did not finish its aggregate and Direct-restoration release receipt."
        )
        emit("NVPN_IOS_LIFECYCLE_RESULT_NAME=\(resultName)")
        emit("NVPN_IOS_LIFECYCLE_XCTEST_PASSED_MS=\(millisecondsSinceEpoch())")
    }

    private func waitForApplicationState(
        _ expected: XCUIApplication.State,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.state == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private func driveConnectedDirectIfRequested() {
        guard app.launchArguments.contains("--nvpn-debug-await-direct-ui-while-connected") else {
            return
        }
        XCTAssertTrue(
            app.buttons["Turn VPN off"].exists,
            "The packet tunnel stopped before the connected Direct transition."
        )
        let internetTab = app.tabBars.buttons["Internet"]
        XCTAssertTrue(internetTab.waitForExistence(timeout: 5))
        internetTab.tap()
        XCTAssertTrue(
            waitForStatus("Waiting for This device selection", timeout: 45),
            "The post-foreground exit probe did not reach the connected Direct transition."
        )

        let sourcePicker = scrollToElement("internet-source-picker")
        sourcePicker.tap()
        tapMenuOption(identifier: "internet-source-direct", label: "This device")
        let selection = "\(sourcePicker.label) \(sourcePicker.value as? String ?? "")"
        XCTAssertTrue(
            selection.localizedCaseInsensitiveContains("This device"),
            "The shipped Internet-source picker did not select This device."
        )
        XCTAssertTrue(
            app.buttons["Turn VPN off"].exists,
            "Selecting Direct unexpectedly stopped the OS packet tunnel."
        )
        XCTAssertTrue(
            waitForStatus("Direct Internet verified", timeout: 45),
            "The app did not verify native DNS and HTTPS after selecting Direct."
        )
        emit("NVPN_CONNECTED_DIRECT_UI_PASSED=1")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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

    private func waitForStatus(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        repeat {
            if app.staticTexts[text].exists {
                return true
            }
            let disclosure = app.buttons["Continue"]
            if disclosure.exists {
                disclosure.tap()
            }
            let allow = springboard.alerts.buttons["Allow"]
            if allow.exists {
                allow.tap()
                // SpringBoard replaces the VPN alert with the passcode sheet.
                // Start a fresh query cycle instead of reusing the disappearing
                // alert hierarchy for the passcode lookup below.
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            if springboard.staticTexts["Enter iPhone Passcode"].exists {
                emit("NVPN_IOS_VPN_APPROVAL_PASSCODE_REQUIRED_MS=\(millisecondsSinceEpoch())")
                let approvalDeadline = Date().addingTimeInterval(30)
                while Date() < approvalDeadline,
                      springboard.staticTexts["Enter iPhone Passcode"].exists
                {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if springboard.staticTexts["Enter iPhone Passcode"].exists {
                    XCTFail(
                        "Enter the iPhone passcode once to approve the new VPN configuration."
                    )
                    return false
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    private func activeTunnelLaunchArguments(
        environment: [String: String]
    ) throws -> [String] {
        let encoded = try requiredEnvironment(
            "NVPN_XCUITEST_APP_LAUNCH_ARGS_BASE64",
            environment: environment
        )
        let data = try XCTUnwrap(
            Data(base64Encoded: encoded),
            "The active-tunnel launch arguments were not valid base64."
        )
        let arguments = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String],
            "The active-tunnel launch arguments were not a string array."
        )
        XCTAssertTrue(arguments.contains("--nvpn-debug-exit-probe"))
        XCTAssertTrue(arguments.contains("--nvpn-debug-await-active-tunnel-lifecycle"))
        return arguments
    }

    private func requiredEnvironment(
        _ name: String,
        environment: [String: String]
    ) throws -> String {
        let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try XCTUnwrap(value.isEmpty ? nil : value, "The physical gate did not provide \(name).")
    }

    private func boundedInteger(
        _ raw: String?,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard let raw, let parsed = Int(raw) else {
            return defaultValue
        }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    private func millisecondsSinceEpoch() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func emit(_ marker: String) {
        PhysicalGateMarker.emit(marker)
    }
}
