//
//  VideoFrameCollector.swift
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
    typealias FrameHandler = @Sendable (CMSampleBuffer) -> Void

    private let lock = NSLock()
    private var capturedFrames = 0
    private var droppedFrames = 0
    private var frameHandlers: [UUID: FrameHandler] = [:]

    @discardableResult
    func addFrameHandler(_ handler: @escaping FrameHandler) -> UUID {
        let identifier = UUID()
        lock.withLock {
            frameHandlers[identifier] = handler
        }
        return identifier
    }

    func removeFrameHandler(_ identifier: UUID) {
        lock.withLock {
            frameHandlers.removeValue(forKey: identifier)
        }
    }

    func resetMetrics() {
        lock.withLock {
            capturedFrames = 0
            droppedFrames = 0
        }
    }

    func metricsSnapshot() -> CameraMetrics {
        lock.withLock {
            CameraMetrics(
                capturedFrames: capturedFrames,
                droppedFrames: droppedFrames
            )
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let handlers = lock.withLock { () -> [FrameHandler] in
            capturedFrames += 1
            return Array(frameHandlers.values)
        }

        for handler in handlers {
            handler(sampleBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.withLock {
            droppedFrames += 1
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try operation()
    }
}
