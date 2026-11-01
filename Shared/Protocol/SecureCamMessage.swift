//
//  SecureCamMessage.swift
//  Shared
//

import Foundation

nonisolated enum SecureCamMessageType: UInt8, Codable, CaseIterable, Sendable {
    case hello = 1
    case subscribe = 2
    case streamConfiguration = 3
    case videoFrame = 4
    case telemetry = 5
    case heartbeat = 6
    case heartbeatReply = 7
    case goodbye = 8
    case error = 9
}

nonisolated struct HelloMessage: Codable, Equatable, Sendable {
    let deviceID: UUID
    let displayName: String
    let protocolVersion: UInt8
}

nonisolated struct SubscribeMessage: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Int
}

nonisolated struct HeartbeatMessage: Codable, Equatable, Sendable {
    let sequence: UInt64
}

nonisolated struct GoodbyeMessage: Codable, Equatable, Sendable {
    let reason: String?
}

nonisolated enum SecureCamErrorCode: String, Codable, Sendable {
    case cameraBusy
    case incompatibleProtocol
    case invalidMessage
    case streamFailed
}

nonisolated struct ErrorMessage: Codable, Equatable, Sendable {
    let code: SecureCamErrorCode
    let detail: String
}

nonisolated struct TelemetryMessage: Codable, Equatable, Sendable {
    let batteryPercent: Int?
    let batteryState: String
    let thermalState: String
    let capturedFrames: Int
    let droppedFrames: Int
    let encodedFrames: Int
    let transmittedBytes: Int64
    let measuredFramesPerSecond: Double?
    let transmittedBitsPerSecond: Double?
}
