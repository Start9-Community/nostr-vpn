import Foundation

enum QRImageImportTestMarker {
    static let directoryPath = "Nostr VPN/UITestCapability"
    static let markerName = "probe"
    static let payloadVersion = "nvpn-release-join-qr-image-import-v1"
    static let maximumAgeSeconds = 60

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
            try? FileManager.default.removeItem(at: marker)
            return false
        }
        let fields = payload.split(separator: "\n")
        guard fields.count == 3,
              fields[0] == payloadVersion,
              let createdAt = Int(fields[1]),
              UUID(uuidString: String(fields[2])) != nil,
              (0...maximumAgeSeconds).contains(now - createdAt)
        else {
            try? FileManager.default.removeItem(at: marker)
            return false
        }
        do {
            try FileManager.default.removeItem(at: marker)
            return true
        } catch {
            return false
        }
    }
}
