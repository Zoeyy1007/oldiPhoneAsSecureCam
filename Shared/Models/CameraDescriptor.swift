//
//  CameraDescriptor.swift
//  Shared
//

import Foundation
@preconcurrency import Network

nonisolated struct CameraDescriptor: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let name: String
    let endpoint: NWEndpoint
    let protocolVersion: UInt8

    static func == (lhs: CameraDescriptor, rhs: CameraDescriptor) -> Bool {
        lhs.id == rhs.id
    }
}
