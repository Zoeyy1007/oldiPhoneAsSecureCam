//
//  TelemetryRecorder.swift
//  iPhoneAsSecureCam
//

import Foundation

@MainActor
final class TelemetryRecorder {
    enum RecorderError: LocalizedError {
        case runAlreadyActive
        case noActiveRun

        var errorDescription: String? {
            switch self {
            case .runAlreadyActive:
                return "A telemetry run is already active."
            case .noActiveRun:
                return "There is no active telemetry run."
            }
        }
    }

    private var telemetryFileHandle: FileHandle?
    private var metadataURL: URL?
    private var telemetryURL: URL?

    var isRecording: Bool {
        telemetryFileHandle != nil
    }

    func start(metadata: TestRunMetadata) throws {
        guard telemetryFileHandle == nil else {
            throw RecorderError.runAlreadyActive
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let runDirectory = applicationSupport
            .appendingPathComponent("TestRuns", isDirectory: true)
            .appendingPathComponent(metadata.runID.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )

        let metadataURL = runDirectory.appendingPathComponent("metadata.json")
        let telemetryURL = runDirectory.appendingPathComponent("telemetry.csv")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

        let header = Data((TelemetrySample.csvHeader + "\n").utf8)
        try header.write(to: telemetryURL, options: .atomic)

        telemetryFileHandle = try FileHandle(forWritingTo: telemetryURL)
        try telemetryFileHandle?.seekToEnd()
        self.metadataURL = metadataURL
        self.telemetryURL = telemetryURL
    }

    func append(_ sample: TelemetrySample) throws {
        guard let telemetryFileHandle else {
            throw RecorderError.noActiveRun
        }

        try telemetryFileHandle.write(contentsOf: Data((sample.csvRow + "\n").utf8))
    }

    func finish() throws -> [URL] {
        guard let telemetryFileHandle else {
            throw RecorderError.noActiveRun
        }

        try telemetryFileHandle.synchronize()
        try telemetryFileHandle.close()

        self.telemetryFileHandle = nil
        let files = [metadataURL, telemetryURL].compactMap { $0 }
        metadataURL = nil
        telemetryURL = nil
        return files
    }
}
