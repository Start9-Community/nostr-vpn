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
