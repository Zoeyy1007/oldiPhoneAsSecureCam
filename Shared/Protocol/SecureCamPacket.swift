//
//  SecureCamPacket.swift
//  Shared
//

import Foundation

nonisolated enum SecureCamPacketError: Error, Equatable, Sendable {
    case incompleteHeader
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case payloadTooLarge(Int)
    case inconsistentPayloadLength(expected: Int, actual: Int)
}

nonisolated struct SecureCamPacket: Equatable, Sendable {
    static let headerSize = 20
    static let magic: [UInt8] = [0x53, 0x43, 0x41, 0x4D] // "SCAM"

    let messageType: SecureCamMessageType
    let flags: UInt16
    let presentationTimeMicroseconds: UInt64
    let payload: Data

    init(
        messageType: SecureCamMessageType,
        flags: UInt16 = 0,
        presentationTimeMicroseconds: UInt64 = 0,
        payload: Data = Data()
    ) {
        self.messageType = messageType
        self.flags = flags
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.payload = payload
    }

    func encoded() throws -> Data {
        guard payload.count <= SecureCamService.maximumPayloadBytes else {
            throw SecureCamPacketError.payloadTooLarge(payload.count)
        }

        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(contentsOf: Self.magic)
        data.append(SecureCamService.protocolVersion)
        data.append(messageType.rawValue)
        data.appendBigEndian(flags)
        data.appendBigEndian(UInt32(payload.count))
        data.appendBigEndian(presentationTimeMicroseconds)
        data.append(payload)
        return data
    }

    static func decoded(from data: Data) throws -> SecureCamPacket {
        let header = try decodeHeader(from: data)
        let expectedSize = headerSize + header.payloadLength
        guard data.count == expectedSize else {
            throw SecureCamPacketError.inconsistentPayloadLength(
                expected: header.payloadLength,
                actual: max(0, data.count - headerSize)
            )
        }

        return SecureCamPacket(
            messageType: header.messageType,
            flags: header.flags,
            presentationTimeMicroseconds: header.presentationTimeMicroseconds,
            payload: Data(data.suffix(header.payloadLength))
        )
    }

    static func decodeHeader(from data: Data) throws -> DecodedHeader {
        guard data.count >= headerSize else {
            throw SecureCamPacketError.incompleteHeader
        }

        guard Array(data.bytes(in: 0..<4)) == magic else {
            throw SecureCamPacketError.invalidMagic
        }

        let version = data.byte(at: 4)
        guard version == SecureCamService.protocolVersion else {
            throw SecureCamPacketError.unsupportedVersion(version)
        }

        let rawMessageType = data.byte(at: 5)
        guard let messageType = SecureCamMessageType(rawValue: rawMessageType) else {
            throw SecureCamPacketError.unknownMessageType(rawMessageType)
        }

        let flags = data.readUInt16BigEndian(at: 6)
        let payloadLength = Int(data.readUInt32BigEndian(at: 8))
        guard payloadLength <= SecureCamService.maximumPayloadBytes else {
            throw SecureCamPacketError.payloadTooLarge(payloadLength)
        }

        return DecodedHeader(
            messageType: messageType,
            flags: flags,
            payloadLength: payloadLength,
            presentationTimeMicroseconds: data.readUInt64BigEndian(at: 12)
        )
    }
}

nonisolated extension SecureCamPacket {
    struct DecodedHeader: Equatable, Sendable {
        let messageType: SecureCamMessageType
        let flags: UInt16
        let payloadLength: Int
        let presentationTimeMicroseconds: UInt64
    }
}

nonisolated private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }

    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func bytes(in offsets: Range<Int>) -> Data {
        let lowerBound = index(startIndex, offsetBy: offsets.lowerBound)
        let upperBound = index(startIndex, offsetBy: offsets.upperBound)
        return self[lowerBound..<upperBound]
    }

    func readUInt16BigEndian(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) << 8
            | UInt16(byte(at: offset + 1))
    }

    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for byteOffset in 0..<4 {
            value = (value << 8) | UInt32(byte(at: offset + byteOffset))
        }
        return value
    }

    func readUInt64BigEndian(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value = (value << 8) | UInt64(byte(at: offset + byteOffset))
        }
        return value
    }
}
