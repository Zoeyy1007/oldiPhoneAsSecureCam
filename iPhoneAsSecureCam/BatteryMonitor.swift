//
//  BatteryMonitor.swift
//  iPhoneAsSecureCam
//

import Combine
import UIKit

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Float = -1
    @Published private(set) var state: UIDevice.BatteryState = .unknown

    private var cancellables = Set<AnyCancellable>()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let center = NotificationCenter.default
        center.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .merge(with: center.publisher(for: UIDevice.batteryStateDidChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    var percent: Int? {
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }
}
