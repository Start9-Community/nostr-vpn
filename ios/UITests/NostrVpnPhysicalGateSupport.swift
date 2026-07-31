import Foundation
import XCTest

enum PhysicalGateMarker {
    private static let fileName = "nvpn-ui-gate-markers.log"

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
        emit("NVPN_XCUITEST_STARTED=1")
    }

    static func emit(_ marker: String) {
        let runId = ProcessInfo.processInfo.environment["NVPN_XCUITEST_RUN_ID"] ?? "missing"
        let text = "NVPN_XCUITEST_RUN_ID=\(runId)\n\(marker)\n"
        let data = Data(text.utf8)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            XCTFail("Could not write physical-gate marker: \(error.localizedDescription)")
        }
        FileHandle.standardError.write(data)
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}

enum PhysicalGateTimeouts {
    static let delivery = bounded(
        environment: "NVPN_XCUITEST_DELIVERY_WAIT_SECS",
        defaultValue: 15
    )
    static let camera = bounded(
        environment: "NVPN_XCUITEST_CAMERA_WAIT_SECS",
        defaultValue: 30
    )

    private static func bounded(
        environment name: String,
        defaultValue: TimeInterval
    ) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let requested = TimeInterval(raw),
              requested > 0
        else {
            return defaultValue
        }
        return min(requested, defaultValue)
    }
}

enum ShippedUIInteraction {
    private static let maximumAttempts = 2

    static func reveal(
        _ target: XCUIElement,
        byTapping control: XCUIElement
    ) -> Bool {
        if target.exists {
            return true
        }
        for _ in 0..<maximumAttempts {
            guard control.waitForExistence(timeout: 2), control.isHittable else {
                return false
            }
            control.tap()
            if target.waitForExistence(timeout: 3) {
                return true
            }
        }
        return false
    }

    static func replaceText(
        _ field: XCUIElement,
        with value: String,
        in app: XCUIApplication
    ) -> Bool {
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline, !(field.exists && field.isHittable) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard field.exists, field.isHittable else {
            return false
        }
        for _ in 0..<maximumAttempts {
            app.activate()
            field.tap()
            let focusDeadline = Date().addingTimeInterval(1)
            while Date() < focusDeadline, !hasKeyboardFocus(field) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard hasKeyboardFocus(field) else {
                continue
            }
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
            field.typeText(value)
            if waitForValue(value, in: field) {
                return true
            }
        }
        return false
    }

    private static func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    private static func waitForValue(
        _ expected: String,
        in field: XCUIElement
    ) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let actual = field.value as? String ?? ""
            if actual != field.placeholderValue, actual == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }
}
