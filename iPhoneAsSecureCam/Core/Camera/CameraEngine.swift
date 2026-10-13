//
//  CameraEngine.swift
//  iPhoneAsSecureCam
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum CameraResolution: String, Codable, CaseIterable, Sendable {
    case hd720p
    case hd1080p

    fileprivate var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720p:
            return .hd1280x720
        case .hd1080p:
            return .hd1920x1080
        }
    }
}

nonisolated struct CameraConfiguration: Equatable, Sendable {
    let resolution: CameraResolution
    let framesPerSecond: Int

    static func hd720p(framesPerSecond: Int) -> CameraConfiguration {
        CameraConfiguration(resolution: .hd720p, framesPerSecond: framesPerSecond)
    }
}

nonisolated struct CameraExposure: Equatable, Sendable {
    let iso: Float
    let durationSeconds: Double
}

nonisolated struct CameraSnapshot: Equatable, Sendable {
    let isRunning: Bool
    let configuration: CameraConfiguration?
    let metrics: CameraMetrics
    let exposure: CameraExposure?
    let lastStartLatencyMilliseconds: Double?
}

nonisolated enum CameraEvent: Equatable, Sendable {
    case started(latencyMilliseconds: Double)
    case stopped
    case interrupted(reason: String)
    case interruptionEnded
    case runtimeError(message: String)
}

nonisolated final class CameraEngine: @unchecked Sendable {
    typealias EventHandler = @Sendable (CameraEvent) -> Void
    typealias FrameHandler = VideoFrameCollector.FrameHandler

    enum CameraError: LocalizedError {
        case permissionDenied
        case cameraUnavailable
        case inputUnavailable
        case outputUnavailable
        case photoOutputUnavailable
        case unsupportedResolution(CameraResolution)
        case unsupportedFrameRate(Int)

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
            case .photoOutputUnavailable:
                return "Photo output could not be added to the capture session."
            case .unsupportedResolution(let resolution):
                return "The camera does not support \(resolution.rawValue)."
            case .unsupportedFrameRate(let framesPerSecond):
                return "The camera does not support \(framesPerSecond) FPS with the active format."
            }
        }
    }

    let captureSession = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    private let sessionQueue = DispatchQueue(label: "iPhoneAsSecureCam.camera.session")
    private let sessionQueueKey = DispatchSpecificKey<Void>()
    private let frameQueue = DispatchQueue(label: "iPhoneAsSecureCam.camera.frames")
    private let frameCollector = VideoFrameCollector()
    private let eventLock = NSLock()

    private var cameraDevice: AVCaptureDevice?
    private var currentConfiguration: CameraConfiguration?
    private var lastStartLatencyMilliseconds: Double?
    private var eventHandler: EventHandler?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        sessionQueue.setSpecific(key: sessionQueueKey, value: ())
        observeSessionEvents()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventLock.lock()
        eventHandler = handler
        eventLock.unlock()
    }

    @discardableResult
    func addFrameHandler(_ handler: @escaping FrameHandler) -> UUID {
        frameCollector.addFrameHandler(handler)
    }

    func removeFrameHandler(_ identifier: UUID) {
        frameCollector.removeFrameHandler(identifier)
    }

    func start(configuration: CameraConfiguration) async throws {
        guard await cameraAccessIsAuthorized() else {
            throw CameraError.permissionDenied
        }

        let requestedAt = DispatchTime.now().uptimeNanoseconds

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    if captureSession.isRunning, currentConfiguration == configuration {
                        continuation.resume()
                        return
                    }

                    try configureSessionIfNeeded()
                    try apply(configuration)

                    let wasRunning = captureSession.isRunning
                    if !wasRunning {
                        frameCollector.resetMetrics()
                        captureSession.startRunning()
                    }
                    currentConfiguration = configuration

                    if !wasRunning {
                        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - requestedAt
                        let latencyMilliseconds = Double(elapsedNanoseconds) / 1_000_000
                        lastStartLatencyMilliseconds = latencyMilliseconds
                        emit(.started(latencyMilliseconds: latencyMilliseconds))
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
            emit(.stopped)
        }
    }

    func snapshot() -> CameraSnapshot {
        let metrics = frameCollector.metricsSnapshot()
        let makeSnapshot = { [self] in
            let exposure = cameraDevice.map {
                CameraExposure(
                    iso: $0.iso,
                    durationSeconds: CMTimeGetSeconds($0.exposureDuration)
                )
            }
            return CameraSnapshot(
                isRunning: captureSession.isRunning,
                configuration: currentConfiguration,
                metrics: metrics,
                exposure: exposure,
                lastStartLatencyMilliseconds: lastStartLatencyMilliseconds
            )
        }
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            return makeSnapshot()
        }
        return sessionQueue.sync(execute: makeSnapshot)
    }

    private func cameraAccessIsAuthorized() async -> Bool {
        switch authorizationStatus {
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

    private func configureSessionIfNeeded() throws {
        guard cameraDevice == nil else { return }
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(frameCollector, queue: frameQueue)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        guard captureSession.canAddInput(input) else {
            throw CameraError.inputUnavailable
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraError.outputUnavailable
        }
        captureSession.addOutput(videoOutput)

        guard captureSession.canAddOutput(photoOutput) else {
            throw CameraError.photoOutputUnavailable
        }
        captureSession.addOutput(photoOutput)
        cameraDevice = camera
    }

    private func apply(_ configuration: CameraConfiguration) throws {
        guard configuration.framesPerSecond > 0 else {
            throw CameraError.unsupportedFrameRate(configuration.framesPerSecond)
        }
        guard captureSession.canSetSessionPreset(configuration.resolution.sessionPreset) else {
            throw CameraError.unsupportedResolution(configuration.resolution)
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = configuration.resolution.sessionPreset
        captureSession.commitConfiguration()

        guard let cameraDevice else {
            throw CameraError.cameraUnavailable
        }
        let requestedFPS = Double(configuration.framesPerSecond)
        let supportsFrameRate = cameraDevice.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= requestedFPS && requestedFPS <= $0.maxFrameRate
        }
        guard supportsFrameRate else {
            throw CameraError.unsupportedFrameRate(configuration.framesPerSecond)
        }

        try cameraDevice.lockForConfiguration()
        defer { cameraDevice.unlockForConfiguration() }
        let frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.framesPerSecond)
        )
        cameraDevice.activeVideoMinFrameDuration = frameDuration
        cameraDevice.activeVideoMaxFrameDuration = frameDuration
    }

    private func observeSessionEvents() {
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                let value = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                let reason = value.map { "reason_\($0.intValue)" } ?? "unknown"
                self?.emit(.interrupted(reason: reason))
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] _ in
                self?.emit(.interruptionEnded)
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.emit(.runtimeError(message: error?.localizedDescription ?? "Unknown camera error"))
            }
        ]
    }

    private func emit(_ event: CameraEvent) {
        eventLock.lock()
        let handler = eventHandler
        eventLock.unlock()
        handler?(event)
    }
}
