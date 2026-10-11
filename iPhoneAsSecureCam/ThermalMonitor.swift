//
//  ThermalMonitor.swift
//  iPhoneAsSecureCam
//

import Combine
import Foundation

@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var state: ProcessInfo.ThermalState

    var onStateChange: ((ProcessInfo.ThermalState) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let processInfo = ProcessInfo.processInfo
        state = processInfo.thermalState

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        let newState = ProcessInfo.processInfo.thermalState
        guard newState != state else { return }

        state = newState
        onStateChange?(newState)
    }
}

extension ProcessInfo.ThermalState {
    var chartLevel: Int {
        switch self {
        case .nominal:
            return 0
        case .fair:
            return 1
        case .serious:
            return 2
        case .critical:
            return 3
        @unknown default:
            return 3
        }
    }
}
