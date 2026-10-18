import AVFoundation
import CoreImage
import Observation
import QuartzCore
import ServeAnalysis
import UIKit

/// Runs the camera, detects the player's pose on every frame, and tracks strokes.
@Observable
final class CameraModel: NSObject {
    /// Latest detected pose (published at most ~15×/s).
    private(set) var sample: PoseSample?
    /// Live evaluation of the current pose, for holding positions during shadow drills.
    private(set) var liveEvaluation: Evaluation?
    /// The most recently completed stroke, with stills of its key frames.
    private(set) var lastStroke: ReviewedStroke?
    private(set) var strokeCount = 0
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
    @ObservationIgnored private var hand = Handedness.right
    /// The stroke being practised; nil means work it out from each swing.
    @ObservationIgnored private var stroke: StrokeType? = .serve
    @ObservationIgnored private var serveTracker = ServeTracker(hand: .right)
    @ObservationIgnored private var strokeTracker = StrokeTracker(hand: .right, type: nil)
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private let ciContext = CIContext()
    /// Downscaled stills of the last few seconds, so a finished stroke can be reviewed and sent to the AI coach.
    @ObservationIgnored private var snapshots: [(time: Double, image: CGImage, sample: PoseSample)] = []
    @ObservationIgnored private var lastSnapshotTime = -Double.infinity
    private static let snapshotInterval = 1.0 / 10

    func start(hand: Handedness, stroke: StrokeType?) {
        setTracking(hand: hand, stroke: stroke)
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

    func setTracking(hand: Handedness, stroke: StrokeType?) {
        videoQueue.async {
            self.hand = hand
            self.stroke = stroke
            self.serveTracker = ServeTracker(hand: hand)
            self.strokeTracker = StrokeTracker(hand: hand, type: stroke)
        }
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
        snapshots.removeAll { $0.time < time - 3.5 }
    }

    /// Match a stroke's key frames to the nearest stored stills. Called on `videoQueue`.
    private func review(_ result: StrokeResult) -> ReviewedStroke {
        var images: [Phase: UIImage] = [:]
        var samples: [Phase: PoseSample] = [:]
        for key in result.keyFrames {
            guard let nearest = snapshots.min(by: { abs($0.time - key.frame.time) < abs($1.time - key.frame.time) }) else { continue }
            images[key.phase] = UIImage(cgImage: nearest.image)
            samples[key.phase] = nearest.sample
        }
        snapshots.removeAll { $0.time <= result.time + 0.5 }
        return ReviewedStroke(result: result, images: images, samples: samples)
    }

    private func speak(_ result: StrokeResult) {
        guard spokenCues else { return }
        var text = result.score.map { "\(result.title), \($0)." } ?? ""
        if let tip = result.topTip { text += " \(tip.tip)" } else { text += " Great \(result.title.lowercased())!" }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let sample = detector.detect(pixelBuffer: pixelBuffer)

        var finished: ReviewedStroke?
        if let sample {
            storeSnapshot(pixelBuffer, sample: sample, time: time)
            let frame = Frame(time: time, pose: sample.pose)
            let result = stroke == .serve ? serveTracker.add(frame)?.stroke : strokeTracker.add(frame)
            finished = result.map(review)
        }
        // Hold-pose feedback: the serve's trophy and contact, or the ready position for other strokes.
        let live = sample.flatMap { stroke == .serve ? ServeAnalyzer.evaluate($0.pose, hand: hand) : StrokeAnalyzer.readyPosition($0.pose) }

        // Always deliver completed strokes; throttle the per-frame UI updates.
        let now = CACurrentMediaTime()
        guard finished != nil || now - lastPublish > 1.0 / 15 else { return }
        lastPublish = now

        DispatchQueue.main.async {
            self.sample = sample
            if let live { self.liveEvaluation = live }
            if let finished {
                self.lastStroke = finished
                self.strokeCount += 1
                self.speak(finished.result)
            }
        }
    }
}
