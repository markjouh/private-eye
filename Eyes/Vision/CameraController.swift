import AVFoundation
import CoreImage
import Foundation

/// A camera frame, how sharp it is (see `Sharpness`) and when it arrived.
struct ScoredFrame {
    let buffer: CVPixelBuffer
    let sharpness: Float
    let date: Date
}

/// Owns the capture session. Frames arrive upright in portrait on `videoQueue`; each one is handed to
/// `onFrame` together with the matching LiDAR depth (when the phone has LiDAR) and kept as
/// `latestFrame`. Frames that arrive while `onFrame` is still running are dropped.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer, DepthMap?) -> Void)?
    /// Called once on the session queue with a description of the capture setup, for the log.
    var onConfigured: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "eyes.camera.session")
    private let videoQueue = DispatchQueue(label: "eyes.camera.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestDate: Date?
    /// Those of the last few frames that could still be the sharpest recent one, newest last: a frame
    /// is let go as soon as a newer one is at least as sharp. That is usually one or two frames, which
    /// matters because the camera has only so many buffers to hand out and stops delivering when too
    /// many are held.
    private var recent: [ScoredFrame] = []
    /// The sharpness of the last few frames, all of them, for the log.
    private var recentScores: [Float] = []
    private static let recentFrames = 5
    private static let recentSeconds = 0.2
    private var framesDropped = 0
    private var lastDepth: DepthMap?
    private var framesSinceDepth = 0
    private let ciContext = CIContext()

    /// Most recent camera frame (BGRA, portrait).
    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// When `latestFrame` arrived. After the app returns from the background the last frame is stale
    /// until the session delivers a new one.
    var latestFrameDate: Date? {
        lock.lock(); defer { lock.unlock() }
        return latestDate
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            self.sessionQueue.async {
                if self.session.inputs.isEmpty { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// The sharpest of the frames that arrived in the last fifth of a second, which is the one to
    /// show the language model: the newest is often smeared by the phone still moving into place.
    /// Nil until the camera has delivered a frame.
    func sharpestRecentFrame() -> ScoredFrame? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let fresh = recent.filter { now.timeIntervalSince($0.date) <= Self.recentSeconds }
        // With the camera stalled there is nothing fresh; the last frame it gave is all there is.
        return fresh.max { $0.sharpness < $1.sharpness } ?? recent.last
    }

    /// The sharpness of the last few frames, oldest first, for the log.
    var recentSharpness: String {
        lock.lock(); defer { lock.unlock() }
        return recentScores.map { String(format: "%.0f", $0) }.joined(separator: " ")
    }

    /// How many frames the camera has thrown away because the app was holding too many of its buffers.
    var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return framesDropped
    }

    func cgImage(of frame: CVPixelBuffer) -> CGImage? {
        ciContext.createCGImage(CIImage(cvPixelBuffer: frame), from: CGRect(
            x: 0, y: 0, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)))
    }

    private func configure() {
        // The LiDAR camera is the wide camera plus a depth stream; fall back to plain wide without it.
        let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        guard let device = lidar ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }

        var wantsDepth = lidar != nil && session.canAddOutput(depthOutput)
        if wantsDepth {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true   // fills holes and smooths the map
            depthOutput.alwaysDiscardsLateDepthData = true
        }

        // Prefer a 4:3 format (full sensor field of view, matches the detector's 3:4 portrait input).
        var summary = "camera: \(device.localizedName)"
        if let format = Self.bestFormat(for: device, depth: wantsDepth) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                if wantsDepth, let depthFormat = Self.bestDepthFormat(in: format) {
                    device.activeDepthDataFormat = depthFormat
                    let d = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                    summary += ", depth \(d.width)x\(d.height)"
                }
                device.unlockForConfiguration()
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                summary += ", video \(d.width)x\(d.height)"
            } catch {
                wantsDepth = false
            }
        } else {
            session.sessionPreset = .hd1920x1080
            wantsDepth = false
        }

        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if wantsDepth, let connection = depthOutput.connection(with: .depthData) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                summary += ", depth rotated by connection"
            } else {
                summary += ", depth rotated in software"
            }
        }

        if wantsDepth, depthOutput.connection(with: .depthData) != nil {
            // Delivers each video frame paired with the depth map captured at the same moment.
            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [output, depthOutput])
            synchronizer.setDelegate(self, queue: videoQueue)
            self.synchronizer = synchronizer
        } else {
            if session.outputs.contains(depthOutput) { session.removeOutput(depthOutput) }
            output.setSampleBufferDelegate(self, queue: videoQueue)
            summary += ", no depth"
        }
        session.commitConfiguration()
        onConfigured?(summary)
    }

    private static func bestFormat(for device: AVCaptureDevice, depth: Bool) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let is4x3 = d.width * 3 == d.height * 4
                let supports30 = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
                let hasDepth = !depth || bestDepthFormat(in: format) != nil
                return is4x3 && supports30 && hasDepth && d.width >= 1024 && d.width <= 2048
            }
            .min { a, b in
                // The model sees at most 768 px and the detector 640, so a modest capture size is
                // plenty and keeps the phone cooler than full-resolution frames.
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return abs(da.width - 1440) < abs(db.width - 1440)
            }
    }

    /// Largest true-depth (not disparity) format the video format offers.
    private static func bestDepthFormat(in format: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        format.supportedDepthDataFormats
            .filter {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return type == kCVPixelFormatType_DepthFloat16 || type == kCVPixelFormatType_DepthFloat32
            }
            .max {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                    < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }
    }

    // MARK: Frame delivery (videoQueue)

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let video = collection.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData else { return }
        if video.sampleBufferWasDropped {
            if video.droppedReason == .outOfBuffers {
                lock.lock(); framesDropped += 1; lock.unlock()
            }
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(video.sampleBuffer) else { return }
        if let depth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !depth.depthDataWasDropped {
            let portrait = CVPixelBufferGetWidth(buffer) < CVPixelBufferGetHeight(buffer)
            lastDepth = DepthMap(depth.depthData, portrait: portrait)
            framesSinceDepth = 0
        } else {
            // Depth can skip a frame; a slightly stale map beats flickering distances.
            framesSinceDepth += 1
            if framesSinceDepth > 5 { lastDepth = nil }
        }
        deliver(buffer, depth: lastDepth)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(buffer, depth: nil)
    }

    private func deliver(_ buffer: CVPixelBuffer, depth: DepthMap?) {
        let frame = ScoredFrame(buffer: buffer, sharpness: Sharpness.score(buffer), date: Date())
        lock.lock()
        latest = buffer
        latestDate = frame.date
        recent.removeAll { $0.sharpness <= frame.sharpness || frame.date.timeIntervalSince($0.date) > Self.recentSeconds }
        recent.append(frame)
        recentScores.append(frame.sharpness)
        if recentScores.count > Self.recentFrames { recentScores.removeFirst() }
        lock.unlock()
        onFrame?(buffer, depth)
    }
}
