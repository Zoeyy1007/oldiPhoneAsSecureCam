//
//  CameraEngine.swift
//  iPhoneAsSecureCam
//

@preconcurrency import AVFoundation
//AVFoundation is apple's camera and media framework
//preconcurrency downgrades strict concurrency warning and errors. Like suppress Sendable warning
import Foundation

nonisolated enum CameraResolution: String, Codable, CaseIterable, Sendable {
    case hd720p
    case hd1080p
    
    // fileprivate means this property can only be accessed by code in the same Swift source file
    // so other files should work with CameraResolution, not AVFoundation's underlying preset
    fileprivate var sessionPreset: AVCaptureSession.Preset {
        switch self { //self means the current value
            //if the current value is .hd720p, it selects that case and returns AVCaptureSession.Preset.hd1280x720
            //It translates the application-level enum into the corresponding AVFoundation value
        case .hd720p:
            return .hd1280x720
        case .hd1080p:
            return .hd1920x1080
        }
    }
}
//nonisolated allows an actor member out of default actor isolation,
//allowing it to be accessed synchronously without an await.
// like startRunning, stopRunning, can block while AVFoundation shut down hardware. Running those on the main actor could freeze buttons, scrolling and rest of the interface.
nonisolated struct CameraConfiguration: Equatable, Sendable {
    // Equatable allows two instances of the same type to be compared for value equality using == and != sign
    // Sendable is a marker protocol indicates a type is safe to share across concurrent contexts
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
    // CameraEngine should be accessed from sessionQueue, not main actor
    // @unchecked Sendable means allow this object to cross concurrency boundaries. The programmer would handle its safety.
    typealias EventHandler = @Sendable (CameraEvent) -> Void
    typealias FrameHandler = VideoFrameCollector.FrameHandler
    // typealias introduces a nickname for an existing type

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

    let captureSession = AVCaptureSession() //coordinates camera input and output
    let photoOutput = AVCapturePhotoOutput() // the output used for still-photo capture

    private let sessionQueue = DispatchQueue(label: "iPhoneAsSecureCam.camera.session")
    // A dispatch queue is a scheduler for blocks of work. The system chooses a suitable thread to execute each submitted block. It is serial queue, executes only one submitted block at a time
    // AVFoundation is stateful. We don't want a caller changing the camera resolution while another caller stops the session at the same moment
    private let sessionQueueKey = DispatchSpecificKey<Void>()
    // DispatchSpecificKey lets us attach queue-local metadata to a dispatch queue.
    // Void means the stored value carries no information.
    private let frameQueue = DispatchQueue(label: "iPhoneAsSecureCam.camera.frames")
    // The camera may deliver 10, 15 or 30 frames per sec. Those callbacks should not wait behind operations such as starting or reconfiguring the camera.
    private let frameCollector = VideoFrameCollector()
    private let eventLock = NSLock()
    // setEventHandler could be called by one execution context while a camera notification calls emit from another. Without synchronization: contextA replaces eventHandler, contextB read eventHandler
    // could happen simultaneously. The lock permits only one of those accesses at a time

    private var cameraDevice: AVCaptureDevice?
    private var currentConfiguration: CameraConfiguration?
    private var lastStartLatencyMilliseconds: Double?
    private var eventHandler: EventHandler?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        sessionQueue.setSpecific(key: sessionQueueKey, value: ())
        observeSessionEvents()
    }

    deinit { // runs when camera object is destory
        // notification tokens are removed so NotificationCenter no longer has registrations associated with this engine
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

    @discardableResult // Swift will not warn if the caller intentionally ignores the UUID
    // ignoring it means the caller cannot conveniently unregister that handler later
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
            sessionQueue.async { [self] in // sessionQueue.async is a callback-style asynchronous code. It does not produce a value that swift can await.
                // A continuation bridges the queue-based operation into swift concurrency
                do {
                    if captureSession.isRunning, currentConfiguration == configuration {
                        continuation.resume() // check whether the same configuration is running, makes start idempotent for the same active configuration.
                        // Repeatedly requests does not unnecessarily rebuild or restart the camera
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
        // async means: put this work on the queue. Return to the caller immediately. The queue executes the work when it reaches the front
        sessionQueue.async { [self] in
            // sessionQueue.async sechedules the operation, adds a job to the queue
            // the code inside the braces is the job being scheduled. 
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
        return sessionQueue.sync(execute: makeSnapshot) // prevents deadlock
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

    private func apply(_ configuration: CameraConfiguration) throws {//apply resolution and frame rate
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
        // checks whether the camera's currently active format supports the requested FPS
        let supportsFrameRate = cameraDevice.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= requestedFPS && requestedFPS <= $0.maxFrameRate
        }
        guard supportsFrameRate else {
            throw CameraError.unsupportedFrameRate(configuration.framesPerSecond)
        }

        try cameraDevice.lockForConfiguration() // AVFoundation requires a configuration lock before changing certain device-level properties
        defer { cameraDevice.unlockForConfiguration() } // defer meansunlockForConfiguration runs when teh current scope exits, whether it exits normally or by throwing an error
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
                // nil tells notificatinCenter to invoke the callback on the thread or queue where the notification was posted. Does not force callbacks on the main queue.
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
                // [weak self]. The notification center stores the callback closure. If the closure strongly retained self, this relationship could form a retention cycle. weak prevents the closure owning the engine.
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
        // emit calls handler after unlocking
    }
}
