//
//  SecureCamService.swift
//  Shared
//

import Foundation

nonisolated enum SecureCamService {
    static let bonjourType = "_securecam._tcp"
    static let protocolVersion: UInt8 = 1
    static let maximumPayloadBytes = 1_048_576
}
