//
//  iPhoneAsSecureCamTests.swift
//  iPhoneAsSecureCamTests
//
//  Created by Zoey Yang on 10/6/26.
//

import Foundation
import Testing
@testable import iPhoneAsSecureCam

struct iPhoneAsSecureCamTests {

    @Test @MainActor
    func telemetryCSVRowEscapesNotes() {
        let sample = TelemetrySample(
            runID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            scenario: .foregroundIdle,
            timestamp: Date(timeIntervalSince1970: 0),
            elapsedSeconds: 12.3,
            batteryPercent: 72,
            batteryState: "charging",
            thermalState: "nominal",
            screenBrightness: 0.1,
            capturedFrames: 123,
            droppedFrames: 2,
            measuredFPS: 9.8,
            event: "message, with \"quotes\""
        )

        #expect(sample.csvRow.contains("\"message, with \"\"quotes\"\"\""))
        #expect(sample.csvRow.contains(",72,charging,nominal,"))
        #expect(sample.csvRow.contains(",123,2,9.80,"))
    }

}
