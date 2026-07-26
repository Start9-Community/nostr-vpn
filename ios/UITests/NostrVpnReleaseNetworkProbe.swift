import Foundation
import Network

enum NostrVpnReleaseNetworkProbe {
    struct HttpReceipt {
        let statusCode: Int
        let body: String
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?

        func complete(_ value: Result<Value, Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else {
                return false
            }
            result = value
            return true
        }

        func resolved() -> Result<Value, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    static func https(_ rawURL: String, timeout: TimeInterval = 12) throws -> HttpReceipt {
        guard let url = URL(string: rawURL) else {
            throw probeError("Invalid probe URL")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw probeError("External Internet probes must use TLS")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        let finished = DispatchSemaphore(value: 0)
        let receipt = ResultBox<HttpReceipt>()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("nvpn-physical-release-gate", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let result: Result<HttpReceipt, Error>
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                result = .success(
                    HttpReceipt(
                        statusCode: response.statusCode,
                        body: String(data: data ?? Data(), encoding: .utf8) ?? ""
                    )
                )
            } else {
                result = .failure(probeError("HTTPS response was not HTTP"))
            }
            if receipt.complete(result) {
                finished.signal()
            }
        }.resume()
        guard finished.wait(timeout: .now() + timeout + 1) == .success else {
            session.invalidateAndCancel()
            throw probeError("HTTPS probe timed out")
        }
        session.finishTasksAndInvalidate()
        guard let resolved = receipt.resolved() else {
            throw probeError("HTTPS probe emitted no result")
        }
        return try resolved.get()
    }

    static func requirePublicHTTPS(_ rawURL: String) throws {
        let receipt = try https(rawURL)
        guard (200..<400).contains(receipt.statusCode) else {
            throw probeError("Public HTTPS returned \(receipt.statusCode)")
        }
    }

    static func sourceIP(_ rawURL: String) throws -> String {
        let receipt = try https(rawURL)
        guard receipt.statusCode == 200 else {
            throw probeError("Exit-source endpoint returned \(receipt.statusCode)")
        }
        let value = receipt.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw probeError("Exit-source endpoint returned an empty body")
        }
        return value
    }

    static func requireSourceIP(_ rawURL: String, expected: String) throws {
        let observed = try sourceIP(rawURL)
        guard observed == expected else {
            throw probeError(
                "Observed public source IP \(observed) did not match \(expected)"
            )
        }
    }

    static func requireDNSURL(_ rawURL: String, expectedBody: String?) throws {
        guard let url = URL(string: rawURL) else {
            throw probeError("Invalid resolver probe URL")
        }
        if url.scheme?.lowercased() == "https" {
            try requirePublicHTTPS(rawURL)
            return
        }
        guard url.scheme?.lowercased() == "http" else {
            throw probeError("Resolver probe must use HTTP or HTTPS")
        }
        let receipt = try plainHTTP(url, timeout: 12)
        guard receipt.statusCode == 200 else {
            throw probeError(
                "Controlled resolver probe returned \(receipt.statusCode)"
            )
        }
        if let expectedBody {
            let body = receipt.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body == expectedBody else {
                throw probeError("Controlled resolver probe returned the wrong body")
            }
        }
    }

    static func exerciseFreshDNSQuery(
        baseHost: String,
        timeout: TimeInterval = 6
    ) throws {
        let normalized = baseHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("/") else {
            throw probeError("Resolver query host is invalid")
        }
        let nonce = UUID().uuidString.lowercased()
        let connection = NWConnection(
            host: NWEndpoint.Host("\(nonce).\(normalized)"),
            port: 443,
            using: .tcp
        )
        let queue = DispatchQueue(label: "fi.siriusbusiness.nvpn.release-probe.dns")
        let finished = DispatchSemaphore(value: 0)
        let receipt = ResultBox<Bool>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if receipt.complete(.success(true)) {
                    finished.signal()
                }
            case .failed:
                // A unique, intentionally non-existent subdomain is expected
                // to fail after resolution. Fixture-side resolver counters are
                // the authoritative receipt that the query used the selected
                // DNS policy rather than the underlay resolver.
                if receipt.complete(.success(true)) {
                    finished.signal()
                }
            case .cancelled:
                if receipt.complete(.failure(probeError("DNS query was cancelled"))) {
                    finished.signal()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard finished.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw probeError("Fresh DNS query timed out")
        }
        connection.cancel()
        guard let resolved = receipt.resolved() else {
            throw probeError("Fresh DNS query emitted no result")
        }
        _ = try resolved.get()
    }

    /// Returns the runner process' monotonic uptime when the exact echoed
    /// payload completed. Callers use this with a NWPathMonitor timestamp from
    /// the same process/clock to enforce the underlay recovery deadline.
    @discardableResult
    static func requireUDPEcho(
        host: String,
        port: UInt16,
        label: String,
        timeout: TimeInterval = 8
    ) throws -> TimeInterval {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw probeError("Invalid UDP probe port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let queue = DispatchQueue(label: "fi.siriusbusiness.nvpn.release-probe.udp")
        let finished = DispatchSemaphore(value: 0)
        let payload = Data("nvpn-\(label)-\(UUID().uuidString)".utf8)
        let receipt = ResultBox<(Data, TimeInterval)>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        if receipt.complete(.failure(error)) {
                            finished.signal()
                        }
                        return
                    }
                    connection.receiveMessage { data, _, _, error in
                        let result: Result<(Data, TimeInterval), Error>
                        if let error {
                            result = .failure(error)
                        } else {
                            result = .success(
                                (
                                    data ?? Data(),
                                    ProcessInfo.processInfo.systemUptime
                                )
                            )
                        }
                        if receipt.complete(result) {
                            finished.signal()
                        }
                    }
                })
            case .failed(let error):
                if receipt.complete(.failure(error)) {
                    finished.signal()
                }
            case .cancelled:
                if receipt.complete(.failure(probeError("UDP probe was cancelled"))) {
                    finished.signal()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard finished.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw probeError("UDP echo timed out")
        }
        connection.cancel()
        guard let resolved = receipt.resolved() else {
            throw probeError("UDP echo emitted no result")
        }
        let (echoed, completedUptime) = try resolved.get()
        guard echoed == payload else {
            throw probeError("UDP fixture did not echo the exact payload")
        }
        return completedUptime
    }

    private static func plainHTTP(
        _ url: URL,
        timeout: TimeInterval
    ) throws -> HttpReceipt {
        guard let host = url.host else {
            throw probeError("HTTP probe has no host")
        }
        let port = UInt16(url.port ?? 80)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw probeError("Invalid HTTP probe port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "fi.siriusbusiness.nvpn.release-probe.http")
        let finished = DispatchSemaphore(value: 0)
        let receipt = ResultBox<Data>()
        let response = DataBox()
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        let request = Data(
            "GET \(path)\(query) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8
        )

        func complete(_ result: Result<Data, Error>) {
            if receipt.complete(result) {
                finished.signal()
            }
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data,
                _,
                isComplete,
                error in
                if let data {
                    response.append(data)
                }
                if let error {
                    complete(.failure(error))
                } else if isComplete {
                    complete(.success(response.value()))
                } else {
                    receive()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error {
                        complete(.failure(error))
                    } else {
                        receive()
                    }
                })
            case .failed(let error):
                complete(.failure(error))
            case .cancelled:
                complete(.failure(probeError("HTTP probe was cancelled")))
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard finished.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw probeError("Controlled HTTP probe timed out")
        }
        connection.cancel()
        guard let resolved = receipt.resolved() else {
            throw probeError("HTTP probe emitted no result")
        }
        let raw = try resolved.get()
        guard let text = String(data: raw, encoding: .utf8) else {
            throw probeError("HTTP probe response was not UTF-8")
        }
        let parts = text.components(separatedBy: "\r\n\r\n")
        let header = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let status = header
            .split(separator: "\n")
            .first?
            .split(separator: " ")
            .dropFirst()
            .first
            .flatMap { Int($0) }
        guard let status else {
            throw probeError("HTTP probe had no status")
        }
        return HttpReceipt(statusCode: status, body: body)
    }

    private static func probeError(_ message: String) -> NSError {
        NSError(
            domain: "NostrVpnReleaseNetworkProbe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
