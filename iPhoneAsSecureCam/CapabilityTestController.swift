//
//  CapabilityTestController.swift
//  iPhoneAsSecureCam
//

import AVFoundation
import Combine
import Foundation
import OSLog
import SwiftUI
import UIKit

@MainActor
final class CapabilityTestController: ObservableObject {
    @Published var selectedScenario: CapabilityScenario = .foregroundIdle
    @Published var batteryHealthInput = ""
    @Published var ambientTemperatureInput = ""
    @Published var surfaceTemperatureInput = ""
    @Published var adapterLabel = "Apple 30 W dual-port"
    @Published var cableLabel = ""
    @Published var notes = ""

    @Published private(set) var isRunning = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var lastRunFiles: [URL] = []
    @Published private(set) var chartPoints: [RunChartPoint] = []
    @Published private(set) var cameraMetrics = CameraMetrics.zero
    @Published private(set) var measuredFPS: Double?

    let batteryMonitor: BatteryMonitor
    let thermalMonitor: ThermalMonitor

    private let telemetryRecorder: TelemetryRecorder
    private let cameraEngine: CameraEngine
    private let sampleInterval: TimeInterval = 10
    private let seriousThermalGracePeriod: TimeInterval = 60
    private let maximumChartPoints = 2_160
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "iPhoneAsSecureCam",
        category: "CapabilityTest"
    )

    private var runID: UUID?
    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?
    private var monitorCancellables = Set<AnyCancellable>()
    private var lastSampleBucket = -1
    private var seriousThermalStateStartedAt: Date?
    private var previousFrameSample: (count: Int, elapsed: TimeInterval)?
    private var isRequestingCameraAccess = false

    init() {
        let batteryMonitor = BatteryMonitor()
        let thermalMonitor = ThermalMonitor()

        self.batteryMonitor = batteryMonitor
        self.thermalMonitor = thermalMonitor
        self.telemetryRecorder = TelemetryRecorder()
        self.cameraEngine = CameraEngine()

        batteryMonitor.objectWillChange
            .merge(with: thermalMonitor.objectWillChange)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &monitorCancellables)

        thermalMonitor.onStateChange = { [weak self] state in
            self?.handleThermalStateChange(state)
        }
    }

    var elapsedText: String {
        let totalSeconds = Int(elapsedSeconds)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    func startTest() {
        guard !isRunning, !isRequestingCameraAccess else { return }

        if selectedScenario.cameraFramesPerSecond != nil {
            switch cameraEngine.authorizationStatus {
            case .notDetermined:
                isRequestingCameraAccess = true
                statusMessage = "Waiting for camera permission"
                Task {
                    let isAuthorized = await cameraEngine.requestAccess()
                    isRequestingCameraAccess = false
                    if isAuthorized {
                        startTest()
                    } else {
                        statusMessage = "Camera permission was denied"
                    }
                }
                return
            case .denied, .restricted:
                statusMessage = "Camera access is unavailable. Check Settings > Privacy & Security > Camera."
                return
            case .authorized:
                break
            @unknown default:
                statusMessage = "Camera authorization status is unknown"
                return
            }
        }

        let runID = UUID()
        let startedAt = Date()
        let metadata = TestRunMetadata(
            runID: runID,
            scenario: selectedScenario,
            startedAt: startedAt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            deviceModel: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            startingBatteryPercent: batteryMonitor.percent,
            batteryHealthPercent: parsedInteger(batteryHealthInput, validRange: 1...100),
            ambientTemperatureCelsius: parsedDouble(ambientTemperatureInput),
            surfaceTemperatureCelsius: parsedDouble(surfaceTemperatureInput),
            adapterLabel: adapterLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            cableLabel: cableLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            screenBrightness: UIScreen.main.brightness,
            sampleIntervalSeconds: sampleInterval
        )

        do {
            try telemetryRecorder.start(metadata: metadata)
        } catch {
            statusMessage = "Could not start: \(error.localizedDescription)"
            logger.error("Could not start telemetry: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.runID = runID
        self.startedAt = startedAt
        elapsedSeconds = 0
        lastSampleBucket = -1
        chartPoints = []
        cameraMetrics = .zero
        measuredFPS = nil
        previousFrameSample = nil
        seriousThermalStateStartedAt = thermalMonitor.state == .serious ? startedAt : nil
        isRunning = true
        statusMessage = "Recording \(selectedScenario.rawValue)"
        lastRunFiles = []
        UIApplication.shared.isIdleTimerDisabled = true

        record(event: "run_started")
        startTimer()
        handleThermalStateChange(thermalMonitor.state)
        startCameraIfNeeded()
        logger.info("Started capability run \(runID.uuidString, privacy: .public)")
    }

    func stopTest(reason: String = "Stopped by operator") {
        guard isRunning else { return }

        updateElapsedTime()
        record(event: "run_stopped: \(reason)")
        timerCancellable?.cancel()
        timerCancellable = nil
        cameraEngine.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        isRunning = false

        do {
            lastRunFiles = try telemetryRecorder.finish()
            statusMessage = reason
        } catch {
            statusMessage = "Stopped, but log finalization failed: \(error.localizedDescription)"
            logger.error("Could not finish telemetry: \(error.localizedDescription, privacy: .public)")
        }

        logger.info("Stopped capability run: \(reason, privacy: .public)")
        runID = nil
        startedAt = nil
        seriousThermalStateStartedAt = nil
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        if isRunning && scenePhase != .active {
            stopTest(reason: "Stopped because the app left the foreground")
        }
    }

    private func startTimer() {
        timerCancellable?.cancel()
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard isRunning else { return }
        updateElapsedTime()

        let sampleBucket = Int(elapsedSeconds / sampleInterval)
        if sampleBucket != lastSampleBucket {
            lastSampleBucket = sampleBucket
            record()
        }

        if let seriousThermalStateStartedAt,
           Date().timeIntervalSince(seriousThermalStateStartedAt) >= seriousThermalGracePeriod {
            stopTest(reason: "Safety stop: thermal state remained serious for 60 seconds")
        }
    }

    private func updateElapsedTime() {
        guard let startedAt else { return }
        elapsedSeconds = Date().timeIntervalSince(startedAt)
    }

    private func handleThermalStateChange(_ state: ProcessInfo.ThermalState) {
        guard isRunning else { return }

        record(event: "thermal_state_changed: \(state.telemetryName)")

        switch state {
        case .critical:
            stopTest(reason: "Safety stop: thermal state became critical")
        case .serious:
            if seriousThermalStateStartedAt == nil {
                seriousThermalStateStartedAt = Date()
            }
            statusMessage = "Warning: serious thermal state"
        case .nominal, .fair:
            seriousThermalStateStartedAt = nil
            statusMessage = "Recording \(selectedScenario.rawValue)"
        @unknown default:
            statusMessage = "Warning: unknown thermal state"
        }
    }

    private func record(event: String? = nil) {
        guard let runID, let startedAt else { return }

        let sampleElapsed = Date().timeIntervalSince(startedAt)
        cameraMetrics = cameraEngine.metricsSnapshot()
        if let previousFrameSample,
           sampleElapsed > previousFrameSample.elapsed {
            measuredFPS = Double(cameraMetrics.capturedFrames - previousFrameSample.count)
                / (sampleElapsed - previousFrameSample.elapsed)
        }
        self.previousFrameSample = (cameraMetrics.capturedFrames, sampleElapsed)

        chartPoints.append(
            RunChartPoint(
                elapsedSeconds: sampleElapsed,
                batteryPercent: batteryMonitor.percent.map(Double.init),
                thermalLevel: thermalMonitor.state.chartLevel,
                measuredFPS: measuredFPS
            )
        )
        if chartPoints.count > maximumChartPoints {
            chartPoints.removeFirst(chartPoints.count - maximumChartPoints)
        }

        let sample = TelemetrySample(
            runID: runID,
            scenario: selectedScenario,
            timestamp: Date(),
            elapsedSeconds: sampleElapsed,
            batteryPercent: batteryMonitor.percent,
            batteryState: batteryMonitor.state.telemetryName,
            thermalState: thermalMonitor.state.telemetryName,
            screenBrightness: UIScreen.main.brightness,
            capturedFrames: cameraMetrics.capturedFrames,
            droppedFrames: cameraMetrics.droppedFrames,
            measuredFPS: measuredFPS,
            event: event
        )

        do {
            try telemetryRecorder.append(sample)
        } catch {
            statusMessage = "Logging error: \(error.localizedDescription)"
            logger.error("Could not append telemetry: \(error.localizedDescription, privacy: .public)")
        }
    }

    var batteryRatePercentPerHour: Double? {
        guard let first = chartPoints.first(where: { $0.batteryPercent != nil }),
              let last = chartPoints.last(where: { $0.batteryPercent != nil }),
              let firstPercent = first.batteryPercent,
              let lastPercent = last.batteryPercent,
              last.elapsedSeconds - first.elapsedSeconds >= 1_800 else {
            return nil
        }

        return (lastPercent - firstPercent)
            / ((last.elapsedSeconds - first.elapsedSeconds) / 3_600)
    }

    private func startCameraIfNeeded() {
        guard let framesPerSecond = selectedScenario.cameraFramesPerSecond else { return }
        let expectedRunID = runID

        Task {
            do {
                try await cameraEngine.start(framesPerSecond: framesPerSecond)
                guard isRunning, runID == expectedRunID else {
                    cameraEngine.stop()
                    return
                }
                record(event: "camera_started: 720p/\(framesPerSecond)_fps")
            } catch {
                stopTest(reason: "Camera failed: \(error.localizedDescription)")
            }
        }
    }

    private func parsedInteger(_ text: String, validRange: ClosedRange<Int>) -> Int? {
        guard let value = Int(text), validRange.contains(value) else { return nil }
        return value
    }

    private func parsedDouble(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
