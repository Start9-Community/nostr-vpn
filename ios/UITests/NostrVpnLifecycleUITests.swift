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
