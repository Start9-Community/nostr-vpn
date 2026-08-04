import Foundation

enum QRImageImportTestMarker {
    // CoreDevice can overwrite, but not create, this file. The ordinary app
    // launch creates it inert in the app's canonical support directory before
    // a physical gate can arm it.
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

    private static func marker(in supportDirectoryURL: URL) -> URL {
        supportDirectoryURL.appendingPathComponent(markerName)
    }

    static func prepare(in supportDirectoryURL: URL?) -> Bool {
        guard let supportDirectoryURL else { return false }
        let marker = marker(in: supportDirectoryURL)
        if FileManager.default.fileExists(atPath: marker.path) {
            return true
        }
        return invalidate(marker)
    }

    static func consume(
        in supportDirectoryURL: URL?,
        now: Int = Int(Date().timeIntervalSince1970)
    ) -> Bool {
        guard let supportDirectoryURL else { return false }
        try? FileManager.default.removeItem(
            at: supportDirectoryURL
                .deletingLastPathComponent()
                .appendingPathComponent(".nvpn-ui-test", isDirectory: true)
        )
        let marker = marker(in: supportDirectoryURL)
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
        _ = invalidate(marker)
        return true
    }
}
