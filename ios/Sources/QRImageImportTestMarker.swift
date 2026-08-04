import Foundation

enum QRImageImportTestMarker {
    // Keep the one-shot capability at the app-group root. CoreDevice always
    // exposes that existing directory, including before the app's first launch.
    static let directoryPath = ""
    static let markerName = "nvpn-release-join-qr-image-import"
    static let payloadVersion = "nvpn-release-join-qr-image-import-v1"
    static let maximumAgeSeconds = 60

    private static func invalidate(_ marker: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: marker)
            return true
        } catch {
            try? FileManager.default.removeItem(at: marker)
            return false
        }
    }

    static func consume(in containerURL: URL?, now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        guard let containerURL else { return false }
        try? FileManager.default.removeItem(
            at: containerURL.appendingPathComponent(".nvpn-ui-test", isDirectory: true)
        )
        let marker = containerURL
            .appendingPathComponent(directoryPath, isDirectory: true)
            .appendingPathComponent(markerName)
        guard let data = try? Data(contentsOf: marker),
              let payload = String(data: data, encoding: .utf8) else {
            _ = invalidate(marker)
            return false
        }
        let fields = payload.split(separator: "\n")
        guard fields.count == 3,
              fields[0] == payloadVersion,
              let createdAt = Int(fields[1]),
              UUID(uuidString: String(fields[2])) != nil,
              (0...maximumAgeSeconds).contains(now - createdAt)
        else {
            _ = invalidate(marker)
            return false
        }
        return invalidate(marker)
    }
}
