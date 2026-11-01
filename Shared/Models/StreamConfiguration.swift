//
//  StreamConfiguration.swift
//  Shared
//

import Foundation

nonisolated enum VideoCodec: String, Codable, Sendable {
    case h264
}

nonisolated struct StreamConfiguration: Codable, Equatable, Sendable {
    let codec: VideoCodec
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let timescale: Int32
    let sequenceParameterSet: Data
    let pictureParameterSet: Data
}
