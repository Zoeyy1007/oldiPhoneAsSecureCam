//
//  CameraEngine.swift
//  iPhoneAsSecureCam
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct CameraMetrics: Equatable, Sendable {
    let capturedFrames: Int
    let droppedFrames: Int

    static let zero = CameraMetrics(capturedFrames: 0, droppedFrames: 0)
}

nonisolated final class VideoFrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedFrames = 0
    private var droppedFrames = 0

    func reset() {
        lock.lock()
        capturedFrames = 0
        droppedFrames = 0
        lock.unlock()
    }

    func snapshot() -> CameraMetrics {
        lock.lock()
        defer { lock.unlock() }
        return CameraMetrics(
            capturedFrames: capturedFrames,
            droppedFrames: droppedFrames
        )
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        capturedFrames += 1
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        droppedFrames += 1
        lock.unlock()
    }
}

nonisolated final class CameraEngine: @unchecked Sendable {
    enum CameraError: LocalizedError {
        case permissionDenied
        case cameraUnavailable
        case inputUnavailable
        case outputUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Camera permission was denied."
            case .cameraUnavailable:
                return "The rear camera is unavailable."
            case .inputUnavailable:
                return "The rear camera could not be added to the capture session."
            case .outputUnavailable:
                return "Video output could not be added to the capture session."
            }
        }
    }

    let captureSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "CameraCapabilityLab.capture")
    private let frameQueue = DispatchQueue(label: "CameraCapabilityLab.frames")
    private let frameCollector = VideoFrameCollector()
    private var isConfigured = false

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start(framesPerSecond: Int) async throws {
        guard await cameraAccessIsAuthorized() else {
            throw CameraError.permissionDenied
        }

        frameCollector.reset()

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configureIfNeeded(framesPerSecond: framesPerSecond)
                    configureFrameRate(framesPerSecond)
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func metricsSnapshot() -> CameraMetrics {
        frameCollector.snapshot()
    }

    private func cameraAccessIsAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await requestAccess()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureIfNeeded(framesPerSecond: Int) throws {
        guard !isConfigured else { return }
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(frameCollector, queue: frameQueue)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .hd1280x720

        guard captureSession.canAddInput(input) else {
            throw CameraError.inputUnavailable
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(output) else {
            throw CameraError.outputUnavailable
        }
        captureSession.addOutput(output)
        isConfigured = true
    }

    private func configureFrameRate(_ framesPerSecond: Int) {
        guard let camera = captureSession.inputs
            .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
            .first else { return }

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        } catch {
            // The session can still run using the device's default frame rate.
        }
    }
}
