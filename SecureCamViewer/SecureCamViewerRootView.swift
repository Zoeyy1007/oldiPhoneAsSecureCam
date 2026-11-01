//
//  SecureCamViewerRootView.swift
//  SecureCamViewer
//

import SwiftUI

struct SecureCamViewerRootView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Cameras Yet")
                    .font(.headline)
                Text("Camera discovery will be added in the next connection milestone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("Secure Cam")
        }
    }
}
