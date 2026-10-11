//
//  TelemetryModels.swift
//  iPhoneAsSecureCam
//

import Foundation
import UIKit

enum CapabilityScenario: String, CaseIterable, Codable, Identifiable {
    case foregroundIdle = "Foreground Idle"
    case chargingBaseline = "Charging Baseline"
    case camera720p10 = "Camera 720p / 10 FPS"
    case camera720p15 = "Camera 720p / 15 FPS"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .foregroundIdle:
            return "Measures the resident app with the screen awake and no camera workload."
        case .chargingBaseline:
            return "Measures charging with the app open and no camera workload."
        case .camera720p10:
            return "Runs the rear camera at 720p and 10 FPS without encoding or networking."
        case .camera720p15:
            return "Runs the rear camera at 720p and 15 FPS without encoding or networking."
        }
    }

    var cameraFramesPerSecond: Int? {
        switch self {
        case .camera720p10:
            return 10
        case .camera720p15:
            return 15
        case .foregroundIdle, .chargingBaseline:
            return nil
        }
    }
}

extension UIDevice.BatteryState {
    var telemetryName: String {
        switch self {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }
}

extension ProcessInfo.ThermalState {
    var telemetryName: String {
        switch self {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}

struct TestRunMetadata: Codable, Equatable {
    let runID: UUID
    let scenario: CapabilityScenario
    let startedAt: Date
    let appVersion: String
    let appBuild: String
    let deviceModel: String
    let systemName: String
    let systemVersion: String
    let startingBatteryPercent: Int?
    let batteryHealthPercent: Int?
    let ambientTemperatureCelsius: Double?
    let surfaceTemperatureCelsius: Double?
    let adapterLabel: String
    let cableLabel: String
    let notes: String
    let screenBrightness: Double
    let sampleIntervalSeconds: Double
}

struct TelemetrySample: Codable, Equatable {
    let runID: UUID
    let scenario: CapabilityScenario
    let timestamp: Date
    let elapsedSeconds: Double
    let batteryPercent: Int?
    let batteryState: String
    let thermalState: String
    let screenBrightness: Double
    let capturedFrames: Int
    let droppedFrames: Int
    let measuredFPS: Double?
    let event: String?

    static let csvHeader = [
        "run_id",
        "scenario",
        "timestamp",
        "elapsed_seconds",
        "battery_percent",
        "battery_state",
        "thermal_state",
        "screen_brightness",
        "captured_frames",
        "dropped_frames",
        "measured_fps",
        "event"
    ].joined(separator: ",")

    var csvRow: String {
        [
            runID.uuidString,
            scenario.rawValue,
            TelemetryDateFormatter.string(from: timestamp),
            String(format: "%.1f", elapsedSeconds),
            batteryPercent.map(String.init) ?? "",
            batteryState,
            thermalState,
            String(format: "%.3f", screenBrightness),
            String(capturedFrames),
            String(droppedFrames),
            measuredFPS.map { String(format: "%.2f", $0) } ?? "",
            event ?? ""
        ]
        .map(Self.escapeCSVField)
        .joined(separator: ",")
    }

    nonisolated private static func escapeCSVField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct RunChartPoint: Identifiable, Equatable {
    let id = UUID()
    let elapsedSeconds: TimeInterval
    let batteryPercent: Double?
    let thermalLevel: Int
    let measuredFPS: Double?
}

enum TelemetryDateFormatter {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
