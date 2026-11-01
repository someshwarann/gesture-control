import AVFoundation
import Vision
import CoreGraphics

typealias Joint = VNHumanHandPoseObservation.JointName

/// One processed camera frame: hand joints in normalized coordinates,
/// mirrored so moving your hand right moves right (y = 0 is the bottom).
struct HandFrame {
    let points: [Joint: CGPoint]
    let time: TimeInterval
}

/// Runs the camera only while needed, at a low resolution and frame rate,
/// and uses Apple's Vision hand-pose model (runs on the Neural Engine).
/// Frames are processed in memory and never saved or uploaded.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((HandFrame?) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "gesture.session")
    private let videoQueue = DispatchQueue(label: "gesture.vision", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var configured = false
    private var lastProcessed: TimeInterval = 0
    private(set) var targetFPS: Int32 = 30
    private(set) var isRunning = false

    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    private func configure() throws {
        guard !configured else { return }
        guard let cam = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "GestureControl", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }
        device = cam
        session.beginConfiguration()
        // Small frames = far less work per frame. 640x480 is plenty for one hand.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            session.sessionPreset = .low
        }
        let input = try AVCaptureDeviceInput(device: cam)
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    /// Builds the capture pipeline without turning the camera on (no light, no power).
    func prepare() {
        sessionQueue.async { [weak self] in try? self?.configure() }
    }

    func start(fps: Int32) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do { try self.configure() } catch {
                NSLog("GestureControl camera error: \(error.localizedDescription)")
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.applyFPS(fps)
            self.isRunning = true
        }
    }

    /// Fully stops the camera: the green light goes off and power use drops to zero.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.isRunning = false
        }
    }

    func setFPS(_ fps: Int32) {
        sessionQueue.async { [weak self] in self?.applyFPS(fps) }
    }

    private func applyFPS(_ fps: Int32) {
        targetFPS = max(1, fps)
        guard let d = device else { return }
        let f = Double(targetFPS)
        let supported = d.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= f && f <= $0.maxFrameRate
        }
        // If the camera can't run that slowly, frames are skipped in software instead.
        guard supported else { return }
        do {
            try d.lockForConfiguration()
            let dur = CMTime(value: 1, timescale: targetFPS)
            d.activeVideoMinFrameDuration = dur
            d.activeVideoMaxFrameDuration = dur
            d.unlockForConfiguration()
        } catch {
            NSLog("GestureControl fps error: \(error.localizedDescription)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        // Software frame throttle (backup for cameras with a high minimum fps).
        if t - lastProcessed < 0.9 / Double(targetFPS) { return }
        lastProcessed = t

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { onFrame?(nil); return }

        guard let obs = request.results?.first,
              let pts = try? obs.recognizedPoints(.all) else {
            onFrame?(nil)
            return
        }
        var mapped: [Joint: CGPoint] = [:]
        for (joint, p) in pts where p.confidence > 0.1 {   // folded fingers have low confidence; keep them
            mapped[joint] = CGPoint(x: 1 - p.location.x, y: p.location.y)   // mirror
        }
        onFrame?(mapped.isEmpty ? nil : HandFrame(points: mapped, time: t))
    }
}
