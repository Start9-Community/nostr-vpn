import Darwin
import Foundation
import NetworkExtension

private let packetFlowWriteCallback: NvpnPacketFlowWriteCallback = {
    context,
    packetPointers,
    packetLengths,
    packetCount in
    guard let context else {
        return false
    }
    return Unmanaged<PacketFlowBridge>
        .fromOpaque(context)
        .takeUnretainedValue()
        .writePackets(
            packetPointers: packetPointers,
            packetLengths: packetLengths,
            packetCount: packetCount
        )
}

private let packetFlowFailureCallback: NvpnPacketFlowFailureCallback = {
    context,
    message in
    guard let context else {
        return
    }
    let text = message.map(String.init(cString:)) ?? "iOS packet flow failed"
    Unmanaged<PacketFlowBridge>
        .fromOpaque(context)
        .takeUnretainedValue()
        .fail(text)
}

private let packetFlowReleaseCallback: NvpnPacketFlowReleaseCallback = { context in
    guard let context else {
        return
    }
    Unmanaged<PacketFlowBridge>.fromOpaque(context).release()
}

final class PacketFlowBridge {
    private static let maximumPacketBytes = 65_535
    private static let maximumBatchPackets = 1_024

    private weak var provider: PacketTunnelProvider?
    private let packetFlow: NEPacketTunnelFlow
    private let stateLock = NSLock()
    private var running = false

    init(packetFlow: NEPacketTunnelFlow, provider: PacketTunnelProvider) {
        self.packetFlow = packetFlow
        self.provider = provider
    }

    func attach(to handle: OpaquePointer) -> Bool {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return false
        }
        running = true
        stateLock.unlock()

        let context = Unmanaged.passRetained(self).toOpaque()
        let attached = nostr_vpn_mobile_tunnel_packet_flow_start(
            handle,
            context,
            packetFlowWriteCallback,
            packetFlowFailureCallback,
            packetFlowReleaseCallback
        )
        if !attached {
            stop()
        }
        return attached
    }

    func startReading() {
        guard isRunning else {
            return
        }
        readNextBatch()
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private var isRunning: Bool {
        stateLock.lock()
        let result = running
        stateLock.unlock()
        return result
    }

    private func readNextBatch() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isRunning else {
                return
            }
            guard let batch = self.validatedBatch(packets: packets, protocols: protocols) else {
                self.fail("NEPacketTunnelFlow returned an invalid outbound packet batch")
                return
            }
            guard self.provider?.sendPacketFlowBatch(batch.bytes, lengths: batch.lengths) == true else {
                if self.isRunning {
                    self.fail("Rust rejected an outbound NEPacketTunnelFlow packet batch")
                }
                return
            }
            if self.isRunning {
                self.readNextBatch()
            }
        }
    }

    private func validatedBatch(
        packets: [Data],
        protocols: [NSNumber]
    ) -> (bytes: Data, lengths: [Int])? {
        guard !packets.isEmpty,
              packets.count == protocols.count,
              packets.count <= Self.maximumBatchPackets
        else {
            return nil
        }

        var byteCount = 0
        var lengths = [Int]()
        lengths.reserveCapacity(packets.count)
        for (packet, packetProtocol) in zip(packets, protocols) {
            guard !packet.isEmpty,
                  packet.count <= Self.maximumPacketBytes,
                  let firstByte = packet.first
            else {
                return nil
            }
            let expectedProtocol: Int32
            switch firstByte >> 4 {
            case 4:
                expectedProtocol = AF_INET
            case 6:
                expectedProtocol = AF_INET6
            default:
                return nil
            }
            guard packetProtocol.int32Value == expectedProtocol else {
                return nil
            }
            let (nextByteCount, overflow) = byteCount.addingReportingOverflow(packet.count)
            guard !overflow else {
                return nil
            }
            byteCount = nextByteCount
            lengths.append(packet.count)
        }

        var bytes = Data()
        bytes.reserveCapacity(byteCount)
        for packet in packets {
            bytes.append(packet)
        }
        return (bytes, lengths)
    }

    fileprivate func writePackets(
        packetPointers: UnsafePointer<UnsafePointer<UInt8>?>?,
        packetLengths: UnsafePointer<Int>?,
        packetCount: Int
    ) -> Bool {
        guard isRunning,
              let packetPointers,
              let packetLengths,
              packetCount > 0,
              packetCount <= Self.maximumBatchPackets
        else {
            return false
        }

        var packets = [Data]()
        var protocols = [NSNumber]()
        packets.reserveCapacity(packetCount)
        protocols.reserveCapacity(packetCount)
        for index in 0..<packetCount {
            let length = packetLengths[index]
            guard let packet = packetPointers[index],
                  length > 0,
                  length <= Self.maximumPacketBytes
            else {
                return false
            }
            let data = Data(bytes: packet, count: length)
            guard let firstByte = data.first else {
                return false
            }
            let packetProtocol: Int32
            switch firstByte >> 4 {
            case 4:
                packetProtocol = AF_INET
            case 6:
                packetProtocol = AF_INET6
            default:
                return false
            }
            packets.append(data)
            protocols.append(NSNumber(value: packetProtocol))
        }
        return packetFlow.writePackets(packets, withProtocols: protocols)
    }

    fileprivate func fail(_ message: String) {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let provider = provider
        stateLock.unlock()
        provider?.packetFlowDidFail(message)
    }
}
