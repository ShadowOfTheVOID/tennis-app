import AVFoundation
import CoreImage
import Observation
import QuartzCore
import ServeAnalysis
import UIKit

/// Runs the camera, detects the player's pose on every frame, and tracks serves.
@Observable
final class CameraModel: NSObject {
    /// Latest detected pose (published at most ~15×/s).
    private(set) var sample: PoseSample?
    /// Live evaluation of the current pose, for holding positions during shadow drills.
    private(set) var liveEvaluation: Evaluation?
    /// The most recently completed serve, with stills of its key frames.
    private(set) var lastServe: ReviewedServe?
    private(set) var serveCount = 0
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var permissionDenied = false

    var spokenCues = true

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "ServeCoach.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "ServeCoach.video")
    @ObservationIgnored private let output = AVCaptureVideoDataOutput()
    @ObservationIgnored private let detector = PoseDetector()
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    @ObservationIgnored private var configured = false
    // Only touched on `videoQueue`.
    @ObservationIgnored private var tracker = ServeTracker(hand: .right)
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private let ciContext = CIContext()
    /// Downscaled stills of the last few seconds, so a finished serve can be reviewed and sent to the AI coach.
    @ObservationIgnored private var snapshots: [(time: Double, image: CGImage, sample: PoseSample)] = []
    @ObservationIgnored private var lastSnapshotTime = -Double.infinity
    private static let snapshotInterval = 1.0 / 10

    func start(hand: Handedness) {
        setHand(hand)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.startSession() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
    }

    func setHand(_ hand: Handedness) {
        videoQueue.async { self.tracker = ServeTracker(hand: hand) }
    }

    func switchCamera() {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        position = next
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.addInput(next)
            self.applyRotation()
            self.session.commitConfiguration()
        }
    }

    private func startSession() {
        let position = position
        sessionQueue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720
                self.addInput(position)
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.videoQueue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.applyRotation()
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func addInput(_ position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    /// Deliver portrait frames so Vision sees the player upright.
    private func applyRotation() {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) else { return }
        connection.videoRotationAngle = 90
    }

    /// Keep a half-resolution still roughly every `snapshotInterval` seconds. Called on `videoQueue`.
    private func storeSnapshot(_ pixelBuffer: CVPixelBuffer, sample: PoseSample, time: Double) {
        guard time - lastSnapshotTime >= Self.snapshotInterval else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        lastSnapshotTime = time
        snapshots.append((time, cgImage, sample))
        snapshots.removeAll { $0.time < time - tracker.window }
    }

    /// Match a serve's key frames to the nearest stored stills. Called on `videoQueue`.
    private func review(_ result: ServeResult) -> ReviewedServe {
        func nearest(_ frame: Frame?) -> (time: Double, image: CGImage, sample: PoseSample)? {
            guard let frame else { return nil }
            return snapshots.min { abs($0.time - frame.time) < abs($1.time - frame.time) }
        }
        let trophy = nearest(result.trophyFrame)
        let contact = nearest(result.contactFrame)
        snapshots.removeAll()
        return ReviewedServe(
            result: result,
            trophyImage: trophy.map { UIImage(cgImage: $0.image) },
            contactImage: contact.map { UIImage(cgImage: $0.image) },
            trophySample: trophy?.sample,
            contactSample: contact?.sample
        )
    }

    private func speak(_ result: ServeResult) {
        guard spokenCues else { return }
        var text = result.score.map { "Score \($0)." } ?? ""
        if let tip = result.topTip { text += " \(tip.tip)" } else { text += " Great serve posture!" }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let sample = detector.detect(pixelBuffer: pixelBuffer)

        var serve: ReviewedServe?
        if let sample {
            storeSnapshot(pixelBuffer, sample: sample, time: time)
            serve = tracker.add(Frame(time: time, pose: sample.pose)).map(review)
        }
        let live = sample.flatMap { ServeAnalyzer.evaluate($0.pose, hand: tracker.hand) }

        // Always deliver completed serves; throttle the per-frame UI updates.
        let now = CACurrentMediaTime()
        guard serve != nil || now - lastPublish > 1.0 / 15 else { return }
        lastPublish = now

        DispatchQueue.main.async {
            self.sample = sample
            if let live { self.liveEvaluation = live }
            if let serve {
                self.lastServe = serve
                self.serveCount += 1
                self.speak(serve.result)
            }
        }
    }
}
