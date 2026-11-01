//
//  PacketStreamDecoder.swift
//  Shared
//

import Foundation

nonisolated struct PacketStreamDecoder: Sendable {
    private var buffer = Data()

    var bufferedByteCount: Int {
        buffer.count
    }

    mutating func append(_ data: Data) throws -> [SecureCamPacket] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        do {
            var packets: [SecureCamPacket] = []

            while buffer.count >= SecureCamPacket.headerSize {
                let header = try SecureCamPacket.decodeHeader(from: buffer)
                let packetSize = SecureCamPacket.headerSize + header.payloadLength
                guard buffer.count >= packetSize else { break }

                let encodedPacket = Data(buffer.prefix(packetSize))
                packets.append(try SecureCamPacket.decoded(from: encodedPacket))
                buffer.removeFirst(packetSize)
            }

            return packets
        } catch {
            buffer.removeAll(keepingCapacity: false)
            throw error
        }
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
