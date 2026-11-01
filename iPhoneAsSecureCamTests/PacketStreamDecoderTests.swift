//
//  PacketStreamDecoderTests.swift
//  iPhoneAsSecureCamTests
//

import Foundation
import Testing
@testable import iPhoneAsSecureCam

struct PacketStreamDecoderTests {
    @Test
    func packetRoundTripsThroughBinaryEncoding() throws {
        let packet = SecureCamPacket(
            messageType: .videoFrame,
            flags: 0x0001,
            presentationTimeMicroseconds: 9_876_543,
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )

        let decoded = try SecureCamPacket.decoded(from: packet.encoded())

        #expect(decoded == packet)
    }

    @Test
    func fragmentedPacketEmitsOnlyAfterFinalByte() throws {
        let packet = SecureCamPacket(
            messageType: .hello,
            payload: Data("hello".utf8)
        )
        let encoded = try packet.encoded()
        var decoder = PacketStreamDecoder()

        for byte in encoded.dropLast() {
            let packets = try decoder.append(Data([byte]))
            #expect(packets.isEmpty)
        }

        let packets = try decoder.append(Data([encoded.last!]))
        #expect(packets == [packet])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func combinedReceiveEmitsEveryCompletePacket() throws {
        let first = SecureCamPacket(
            messageType: .heartbeat,
            payload: Data([0x01])
        )
        let second = SecureCamPacket(
            messageType: .goodbye,
            presentationTimeMicroseconds: 42,
            payload: Data([0x02, 0x03])
        )
        var combined = try first.encoded()
        combined.append(try second.encoded())
        var decoder = PacketStreamDecoder()

        let packets = try decoder.append(combined)

        #expect(packets == [first, second])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func completePacketAndPartialPacketPreserveTheRemainder() throws {
        let first = SecureCamPacket(messageType: .heartbeat)
        let second = SecureCamPacket(
            messageType: .telemetry,
            payload: Data(repeating: 0x7F, count: 20)
        )
        var received = try first.encoded()
        let secondEncoded = try second.encoded()
        received.append(secondEncoded.prefix(10))
        var decoder = PacketStreamDecoder()

        let firstResult = try decoder.append(received)
        #expect(firstResult == [first])
        #expect(decoder.bufferedByteCount == 10)

        let secondResult = try decoder.append(Data(secondEncoded.dropFirst(10)))
        #expect(secondResult == [second])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func invalidMagicIsRejectedAndClearsTheBuffer() throws {
        var encoded = try SecureCamPacket(messageType: .hello).encoded()
        encoded[encoded.startIndex] = 0x00
        var decoder = PacketStreamDecoder()

        #expect(throws: SecureCamPacketError.invalidMagic) {
            try decoder.append(encoded)
        }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func unsupportedVersionIsRejected() throws {
        var encoded = try SecureCamPacket(messageType: .hello).encoded()
        encoded[encoded.index(encoded.startIndex, offsetBy: 4)] = 99
        var decoder = PacketStreamDecoder()

        #expect(throws: SecureCamPacketError.unsupportedVersion(99)) {
            try decoder.append(encoded)
        }
    }

    @Test
    func unknownMessageTypeIsRejected() throws {
        var encoded = try SecureCamPacket(messageType: .hello).encoded()
        encoded[encoded.index(encoded.startIndex, offsetBy: 5)] = 255
        var decoder = PacketStreamDecoder()

        #expect(throws: SecureCamPacketError.unknownMessageType(255)) {
            try decoder.append(encoded)
        }
    }

    @Test
    func oversizedPayloadLengthIsRejectedBeforePayloadArrives() throws {
        var encoded = try SecureCamPacket(messageType: .videoFrame).encoded()
        let oversizedLength = UInt32(SecureCamService.maximumPayloadBytes + 1)
        let bytes: [UInt8] = [
            UInt8((oversizedLength >> 24) & 0xFF),
            UInt8((oversizedLength >> 16) & 0xFF),
            UInt8((oversizedLength >> 8) & 0xFF),
            UInt8(oversizedLength & 0xFF)
        ]
        encoded.replaceSubrange(8..<12, with: bytes)
        var decoder = PacketStreamDecoder()

        #expect(
            throws: SecureCamPacketError.payloadTooLarge(Int(oversizedLength))
        ) {
            try decoder.append(encoded)
        }
    }
}
