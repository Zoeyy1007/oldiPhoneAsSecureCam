//
//  ContentView.swift
//  iPhoneAsSecureCam
//
//  Created by Zoey Yang on 10/6/26.
//

import Charts
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = CapabilityTestController()
    @State private var isShowingShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    liveMetrics
                    runCharts
                    scenarioConfiguration
                    runControls
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Capability Lab")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { newPhase in
            controller.handleScenePhase(newPhase)
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ShareSheet(items: controller.lastRunFiles)
        }
    }

    private var liveMetrics: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Live metrics")
                .font(.headline)

            HStack(spacing: 12) {
                MetricCard(
                    title: "Battery",
                    value: controller.batteryMonitor.percent.map { "\($0)%" } ?? "Unavailable",
                    detail: controller.batteryMonitor.state.telemetryName.capitalized,
                    color: .green
                )
                MetricCard(
                    title: "Thermal",
                    value: controller.thermalMonitor.state.telemetryName.capitalized,
                    detail: thermalDetail,
                    color: thermalColor
                )
            }

            HStack {
                Label(controller.elapsedText, systemImage: "timer")
                    .monospacedDigit()
                Spacer()
                Text(controller.isRunning ? "RECORDING" : "IDLE")
                    .font(.caption.bold())
                    .foregroundStyle(controller.isRunning ? Color.red : Color.secondary)
            }

            if controller.selectedScenario.cameraFramesPerSecond != nil {
                HStack(spacing: 12) {
                    MetricCard(
                        title: "Measured FPS",
                        value: controller.measuredFPS.map { String(format: "%.1f", $0) } ?? "—",
                        detail: "Since last sample",
                        color: .cyan
                    )
                    MetricCard(
                        title: "Frames",
                        value: "\(controller.cameraMetrics.capturedFrames)",
                        detail: "\(controller.cameraMetrics.droppedFrames) dropped",
                        color: controller.cameraMetrics.droppedFrames == 0 ? .green : .orange
                    )
                }

                HStack(spacing: 12) {
                    MetricCard(
                        title: "Exposure",
                        value: exposureText,
                        detail: controller.cameraExposure.map { "ISO \(Int($0.iso.rounded()))" } ?? "Waiting for camera",
                        color: .purple
                    )
                    MetricCard(
                        title: "Camera start",
                        value: controller.cameraStartLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—",
                        detail: "Latest start latency",
                        color: .blue
                    )
                }
            }

            Text(controller.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var runCharts: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Battery & charging trend")
                        .font(.headline)
                    Spacer()
                    Text(batteryRateText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Chart(controller.chartPoints) { point in
                    if let batteryPercent = point.batteryPercent {
                        LineMark(
                            x: .value("Minutes", point.elapsedSeconds / 60),
                            y: .value("Battery", batteryPercent)
                        )
                        .foregroundStyle(.green)
                        .symbol(.circle)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Battery %")
                .chartXAxisLabel("Elapsed minutes")
                .frame(height: 150)

                Text("This shows battery slope, not electrical efficiency. Use the USB meter for watts and watt-hours.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Thermal state")
                    .font(.headline)

                Chart(controller.chartPoints) { point in
                    LineMark(
                        x: .value("Minutes", point.elapsedSeconds / 60),
                        y: .value("Thermal state", point.thermalLevel)
                    )
                    .foregroundStyle(thermalColor)
                    .interpolationMethod(.stepEnd)

                    RuleMark(y: .value("Serious", 2))
                        .foregroundStyle(.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(dash: [4]))
                }
                .chartYScale(domain: 0...3)
                .chartYAxis {
                    AxisMarks(values: [0, 1, 2, 3]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let level = value.as(Int.self) {
                                Text(thermalLabel(for: level))
                            }
                        }
                    }
                }
                .chartXAxisLabel("Elapsed minutes")
                .frame(height: 150)
            }

            if controller.selectedScenario.cameraFramesPerSecond != nil {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera delivery rate")
                        .font(.headline)

                    Chart(controller.chartPoints) { point in
                        if let measuredFPS = point.measuredFPS {
                            LineMark(
                                x: .value("Minutes", point.elapsedSeconds / 60),
                                y: .value("FPS", measuredFPS)
                            )
                            .foregroundStyle(.cyan)
                        }
                    }
                    .chartYScale(domain: 0...35)
                    .chartYAxisLabel("FPS")
                    .chartXAxisLabel("Elapsed minutes")
                    .frame(height: 150)
                }
            }
        }
        .cardStyle()
    }

    private var scenarioConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test configuration")
                .font(.headline)

            Picker("Scenario", selection: $controller.selectedScenario) {
                ForEach(CapabilityScenario.allCases) { scenario in
                    Text(scenario.rawValue).tag(scenario)
                }
            }
            .pickerStyle(.menu)
            .disabled(controller.isRunning)

            Text(controller.selectedScenario.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Group {
                LabeledTextField(
                    title: "Battery health (%)",
                    placeholder: "From Settings",
                    text: $controller.batteryHealthInput,
                    keyboardType: .numberPad
                )
                LabeledTextField(
                    title: "Ambient temperature (°C)",
                    placeholder: "Optional",
                    text: $controller.ambientTemperatureInput,
                    keyboardType: .decimalPad
                )
                LabeledTextField(
                    title: "Surface temperature (°C)",
                    placeholder: "Optional starting value",
                    text: $controller.surfaceTemperatureInput,
                    keyboardType: .decimalPad
                )
                LabeledTextField(
                    title: "Adapter",
                    placeholder: "Exact adapter model and port",
                    text: $controller.adapterLabel
                )
                LabeledTextField(
                    title: "Cable",
                    placeholder: "Optional label",
                    text: $controller.cableLabel
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional notes", text: $controller.notes, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(controller.isRunning)

            Text("Before a formal run, set brightness manually and disconnect Xcode. The app keeps the screen awake only while recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var runControls: some View {
        VStack(spacing: 12) {
            Button {
                if controller.isRunning {
                    controller.stopTest()
                } else {
                    controller.startTest()
                }
            } label: {
                Label(
                    controller.isRunning ? "Stop Test" : "Start Test",
                    systemImage: controller.isRunning ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? .red : .blue)

            if !controller.lastRunFiles.isEmpty {
                Button {
                    isShowingShareSheet = true
                } label: {
                    Label("Export Last Run", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var thermalColor: Color {
        switch controller.thermalMonitor.state {
        case .nominal:
            return .green
        case .fair:
            return .yellow
        case .serious:
            return .orange
        case .critical:
            return .red
        @unknown default:
            return .gray
        }
    }

    private var thermalDetail: String {
        switch controller.thermalMonitor.state {
        case .nominal:
            return "Normal"
        case .fair:
            return "Elevated"
        case .serious:
            return "Safety timer active"
        case .critical:
            return "Test stops"
        @unknown default:
            return "Unknown"
        }
    }

    private var batteryRateText: String {
        guard let rate = controller.batteryRatePercentPerHour else {
            return "Collecting rate…"
        }
        return String(format: "%+.1f%%/hr", rate)
    }

    private var exposureText: String {
        guard let exposure = controller.cameraExposure else { return "—" }
        return String(format: "%.2f ms", exposure.durationSeconds * 1_000)
    }

    private func thermalLabel(for level: Int) -> String {
        switch level {
        case 0:
            return "Nominal"
        case 1:
            return "Fair"
        case 2:
            return "Serious"
        default:
            return "Critical"
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LabeledTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}
