import Darwin
import Foundation

// Bonjour only supplies candidate addresses. The Rust adapter admits configured
// identities and FIPS authenticates each path before using it.
final class FipsBonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var advertised: NetService?
    private var services: [String: NetService] = [:]
    private var ownNpub = ""
    private var onPeer: ((String, [String]) -> Void)?

    func start(infoJson: String, onPeer: @escaping (String, [String]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        guard let data = infoJson.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let npub = info["npub"] as? String,
              let port = info["port"] as? Int, (1...65535).contains(port),
              let scope = info["scope"] as? String
        else { return }
        ownNpub = npub
        self.onPeer = onPeer
        let service = NetService(domain: "local.", type: "_fips._udp.", name: npub, port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "npub": Data(npub.utf8), "scope": Data(scope.utf8), "v": Data("1".utf8),
        ]))
        service.schedule(in: .main, forMode: .common)
        advertised = service
        service.publish()
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_fips._udp.", inDomain: "local.")
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        browser.stop()
        browser.remove(from: .main, forMode: .common)
        advertised?.stop()
        advertised?.remove(from: .main, forMode: .common)
        advertised = nil
        for service in services.values {
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        services.removeAll()
        onPeer = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = service.domain + service.type + service.name
        guard onPeer != nil, services[key] == nil, services.count < 128 else { return }
        services[key] = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = service.domain + service.type + service.name
        let removed = services.removeValue(forKey: key)
        removed?.stop()
        removed?.remove(from: .main, forMode: .common)
        removed?.delegate = nil
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txt = sender.txtRecordData() else { return }
        let record = NetService.dictionary(fromTXTRecord: txt)
        guard let key = record["npub"], let npub = String(data: key, encoding: .utf8),
              npub != ownNpub, record["v"] == Data("1".utf8)
        else { return }
        let addresses = (sender.addresses ?? []).compactMap(Self.numericAddress)
        if !addresses.isEmpty { onPeer?(npub, addresses) }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let key = sender.domain + sender.type + sender.name
        services.removeValue(forKey: key)
        sender.stop()
        sender.remove(from: .main, forMode: .common)
        sender.delegate = nil
        NSLog("nvpn-pkt: Bonjour resolve failed: %@", errorDict)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("nvpn-pkt: Bonjour publish failed: %@", errorDict)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("nvpn-pkt: Bonjour browse failed: %@", errorDict)
    }

    static func numericAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size, let base = bytes.baseAddress else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr.self)
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { return nil }
            let size = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
            guard bytes.count >= size else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
            guard getnameinfo(address, socklen_t(size), &host, socklen_t(host.count),
                              &port, socklen_t(port.count), NI_NUMERICHOST | NI_NUMERICSERV) == 0
            else { return nil }
            var hostname = String(cString: host)
            if family == AF_INET6 {
                let v6 = bytes.loadUnaligned(as: sockaddr_in6.self)
                hostname = String(hostname.prefix(while: { $0 != "%" }))
                if v6.sin6_scope_id != 0 { hostname += "%\(v6.sin6_scope_id)" }
                hostname = "[\(hostname)]"
            }
            return "\(hostname):\(String(cString: port))"
        }
    }
}
