import Foundation

@main
struct QRImageImportTestMarkerTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("nvpn-qr-marker-\(UUID())", isDirectory: true)
        let directory = root.appendingPathComponent(
            QRImageImportTestMarker.directoryPath,
            isDirectory: true
        )
        let marker = directory.appendingPathComponent(QRImageImportTestMarker.markerName)
        let legacy = root.appendingPathComponent(".nvpn-ui-test/probe")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: legacy)
        let now = 2_000_000_000
        let token = UUID().uuidString.lowercased()

        func write(_ payload: String) throws {
            try Data(payload.utf8).write(to: marker, options: .atomic)
        }

        try write("\(QRImageImportTestMarker.payloadVersion)\n\(now)\n\(token)\n")
        require(QRImageImportTestMarker.consume(in: root, now: now), "valid marker rejected")
        require(!files.fileExists(atPath: marker.path), "valid marker was not deleted")
        require(!files.fileExists(atPath: legacy.path), "legacy probe was not removed")
        require(!QRImageImportTestMarker.consume(in: root, now: now), "marker was not one-shot")

        try write("\(QRImageImportTestMarker.payloadVersion)\n\(now - 61)\n\(token)\n")
        require(!QRImageImportTestMarker.consume(in: root, now: now), "stale marker accepted")
        require(!files.fileExists(atPath: marker.path), "stale marker was not deleted")

        try write("invalid\n0\nnot-a-uuid\n")
        require(!QRImageImportTestMarker.consume(in: root, now: now), "invalid marker accepted")
        require(!files.fileExists(atPath: marker.path), "invalid marker was not deleted")
        require(!QRImageImportTestMarker.consume(in: nil, now: now), "missing group accepted")
    }
}
