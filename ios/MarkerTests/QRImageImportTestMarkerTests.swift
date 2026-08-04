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

        func requireInertMarker(_ message: String) throws {
            require(files.fileExists(atPath: marker.path), "\(message): marker path disappeared")
            let data = try Data(contentsOf: marker)
            require(data.isEmpty, "\(message): marker was still armed")
        }

        func overwriteExisting(_ payload: String) throws {
            require(files.fileExists(atPath: marker.path), "CoreDevice overwrite target was missing")
            try Data(payload.utf8).write(to: marker)
        }

        try write("\(QRImageImportTestMarker.payloadVersion)\n\(now)\n\(token)\n")
        require(QRImageImportTestMarker.consume(in: root, now: now), "valid marker rejected")
        try requireInertMarker("valid consume")
        require(!files.fileExists(atPath: legacy.path), "legacy probe was not removed")
        require(!QRImageImportTestMarker.consume(in: root, now: now), "marker was not one-shot")
        try requireInertMarker("second consume")

        try overwriteExisting("\(QRImageImportTestMarker.payloadVersion)\n\(now)\n\(token)\n")
        require(
            QRImageImportTestMarker.consume(in: root, now: now),
            "existing marker path could not be rearmed"
        )
        try requireInertMarker("rearmed consume")

        try overwriteExisting("\(QRImageImportTestMarker.payloadVersion)\n\(now - 61)\n\(token)\n")
        require(!QRImageImportTestMarker.consume(in: root, now: now), "stale marker accepted")
        try requireInertMarker("stale consume")

        try overwriteExisting("invalid\n0\nnot-a-uuid\n")
        require(!QRImageImportTestMarker.consume(in: root, now: now), "invalid marker accepted")
        try requireInertMarker("invalid consume")

        try files.removeItem(at: marker)
        require(!QRImageImportTestMarker.consume(in: root, now: now), "missing marker accepted")
        try requireInertMarker("missing consume")
        require(!QRImageImportTestMarker.consume(in: nil, now: now), "missing group accepted")
    }
}
