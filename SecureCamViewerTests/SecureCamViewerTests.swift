//
//  SecureCamViewerTests.swift
//  SecureCamViewerTests
//

import Testing
@testable import SecureCamViewer

struct SecureCamViewerTests {
    @Test
    func sharedSourcesAreAvailableToTheViewer() {
        #expect(SecureCamService.protocolVersion == 1)
        #expect(SecureCamService.bonjourType == "_securecam._tcp")
    }
}
