import AVFoundation
import CoreImage
import PhotosUI
import ServeAnalysis
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from the photo library, copied to a temporary file.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

/// An analysed match video. Stills for each stroke are pulled from the video only when a
/// stroke is opened, so long videos don't fill memory.
struct AnalyzedMatch: Identifiable {
    let id = UUID()
    let report: MatchReport
    let video: URL
    /// Pose at every analysed frame, by time, for skeletons and replays.
    let samples: [Double: PoseSample]
    /// Every ball sighting in the video (approximate).
    var balls: [BallSighting] = []

    var rallies: [Rally] { BallAnalysis.rallies(balls) }

    /// Toss placement for each serve where the ball was tracked.
    func tosses(hand: Handedness) -> [TossReading] {
        report.strokes.compactMap { s in
            guard let trophy = s.frame(for: .trophy), let sample = samples[trophy.time] else { return nil }
            return BallAnalysis.toss(balls, serve: s, hand: hand, width: sample.imageSize.width, height: sample.imageSize.height)
        }
    }
}

extension AnalyzedMatch: Hashable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum VideoAnalyzer {
    /// A single stroke: dense sampling, up to 20 s.
    static let strokeFPS = 15.0
    static let strokeMaxSeconds = 20.0
    /// A match: lighter sampling, up to 10 minutes.
    static let matchFPS = 10.0
    static let matchMaxSeconds = 600.0

    /// Analyse a clip of one stroke. Nil if no stroke was found.
    static func analyzeStroke(url: URL, hand: Handedness, type: StrokeType?, progress: @escaping (Double) -> Void) async throws -> ReviewedStroke? {
        let scan = try await poses(url: url, fps: strokeFPS, maxSeconds: strokeMaxSeconds, progress: progress)
        guard let result = StrokeAnalyzer.analyzeClip(scan.frames, type: type, hand: hand) else { return nil }
        return await stills(url: url, result: result, samples: scan.samples, balls: scan.balls, hand: hand)
    }

    static func analyzeMatch(url: URL, hand: Handedness, progress: @escaping (Double) -> Void) async throws -> AnalyzedMatch {
        let scan = try await poses(url: url, fps: matchFPS, maxSeconds: matchMaxSeconds, progress: progress)
        let report = MatchAnalyzer.analyze(scan.frames, hand: hand)
        // Every analysed frame's pose is kept, so each stroke's replay can show its skeleton.
        return AnalyzedMatch(report: report, video: url, samples: scan.samples, balls: scan.balls)
    }

    /// Pull the stills for one stroke's key moments from the video.
    static func stills(url: URL, result: StrokeResult, samples: [Double: PoseSample], balls: [BallSighting], hand: Handedness) async -> ReviewedStroke {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [Phase: UIImage] = [:]
        var poseSamples: [Phase: PoseSample] = [:]
        for key in result.keyFrames {
            if let image = try? await generator.image(at: CMTime(seconds: key.frame.time, preferredTimescale: 600)).image {
                images[key.phase] = UIImage(cgImage: image)
            }
            poseSamples[key.phase] = samples[key.frame.time]
        }
        // Replay: up to 60 smaller frames at the analysed times around the stroke.
        var replay: [ReplayFrame] = []
        if let window = ReviewedStroke.replayWindow(result) {
            generator.maximumSize = CGSize(width: 540, height: 540)
            let times = samples.keys.filter { window.contains($0) }.sorted()
            let step = max(1, Int((Double(times.count) / 60).rounded(.up)))
            for time in stride(from: 0, to: times.count, by: step).map({ times[$0] }) {
                if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                    replay.append(ReplayFrame(time: time, image: UIImage(cgImage: image), sample: samples[time]))
                }
            }
        }
        var toss: TossReading?
        if let trophy = result.frame(for: .trophy), let sample = samples[trophy.time] {
            toss = BallAnalysis.toss(balls, serve: result, hand: hand, width: sample.imageSize.width, height: sample.imageSize.height)
        }
        let nearby = ReviewedStroke.replayWindow(result).map { w in balls.filter { (w.lowerBound - 1.2...w.upperBound).contains($0.time) } } ?? []
        return ReviewedStroke(result: result, images: images, samples: poseSamples, replay: replay, balls: nearby, toss: toss)
    }

    /// Decode the video in order and detect a pose about `fps` times a second.
    /// Sequential decoding is far faster than seeking to each frame, which matters for long matches.
    private static func poses(url: URL, fps: Double, maxSeconds: Double, progress: @escaping (Double) -> Void) async throws
        -> (frames: [Frame], samples: [Double: PoseSample], balls: [BallSighting]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return ([], [:], []) }
        let duration = min(try await asset.load(.duration).seconds, maxSeconds)
        let orientation = orientation(of: try await track.load(.preferredTransform))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }

        let detector = PoseDetector()
        var frames: [Frame] = []
        var samples: [Double: PoseSample] = [:]
        let ball = BallTracker()
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var next = 0.0
        var nextBall = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            // The ball moves fast, so it's looked for more often than poses (up to 30 times a second).
            if time >= nextBall {
                nextBall = time + 1 / ballFPS - 0.005
                if let image = rgb(pixels, orientation: orientation, time: time, context: ciContext) { ball.add(image) }
            }
            guard time >= next else { continue }
            next = time + 1 / fps - 0.005
            if let sample = detector.detect(pixelBuffer: pixels, orientation: orientation) {
                frames.append(Frame(time: time, pose: sample.pose))
                samples[time] = sample
            }
            progress(duration > 0 ? min(1, time / duration) : 1)
        }
        return (frames, samples, ball.sightings)
    }

    private static let ballFPS = 30.0
    /// Width of the small upright frames the ball is looked for in.
    private static let ballWidth = 320

    private static func rgb(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation, time: Double, context: CIContext) -> RGBImage? {
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        guard image.extent.width > 0 else { return nil }
        let scale = Double(ballWidth) / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = ballWidth
        let height = max(1, Int((image.extent.height * scale).rounded(.down)))
        // Through a CGImage so the rows come out top first, the same way up as the pose coordinates.
        guard let cg = context.createCGImage(small, from: CGRect(x: small.extent.minX, y: small.extent.minY,
                                                                 width: CGFloat(width), height: CGFloat(height))) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let bitmap = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        return RGBImage(width: width, height: height, rgb: rgb, time: time)
    }

    /// How the video's frames are rotated relative to upright, from its track transform.
    private static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

struct VideoAnalysisView: View {
    @AppStorage("handedness") private var hand: Handedness = .right
    @Environment(AppState.self) private var app
    @State private var matchMode = false
    /// A `StrokeType` raw value, or "any".
    @State private var strokeType = "any"
    @State private var item: PhotosPickerItem?
    @State private var progress: Double?
    @State private var stroke: ReviewedStroke?
    @State private var match: AnalyzedMatch?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let progress {
                    VStack(spacing: 12) {
                        ProgressView(value: progress)
                        Text(matchMode ? "Finding every stroke… long matches take a few minutes." : "Finding your stroke's key moments…")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                        Button("Cancel") { item = nil }
                    }
                    .padding()
                } else {
                    picker
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Video")
            .navigationDestination(item: $stroke) { StrokeReviewView(stroke: $0, hand: hand) }
            .navigationDestination(item: $match) { MatchView(match: $0, hand: hand) }
            .alert("Couldn't analyze video", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task(id: item) { await load() }
        }
    }

    private var picker: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: $matchMode) {
                Text("One stroke").tag(false)
                Text("Match").tag(true)
            }
            .pickerStyle(.segmented)

            Image(systemName: matchMode ? "sportscourt" : "video.badge.waveform").font(.largeTitle).foregroundStyle(.secondary)
            if matchMode {
                Text("Analyze a match or rally").font(.title3.bold())
                Text("Film from the side of the court with your whole body in frame. Up to \(Int(VideoAnalyzer.matchMaxSeconds / 60)) minutes. "
                     + "You'll get every stroke graded, footwork and movement, and a match plan.")
                    .multilineTextAlignment(.center)
            } else {
                Text("Analyze one stroke").font(.title3.bold())
                Text("Film one stroke side-on with your whole body in frame, then pick the clip.").multilineTextAlignment(.center)
                StrokePicker(selection: $strokeType)
            }
            PhotosPicker(selection: $item, matching: .videos) {
                Label("Pick video", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func load() async {
        guard let item else { return }
        progress = 0
        defer {
            progress = nil
            self.item = nil
        }
        do {
            guard let video = try await item.loadTransferable(type: PickedVideo.self) else { return }
            let report: (Double) -> Void = { value in Task { @MainActor in if progress != nil { progress = value } } }
            if matchMode {
                // Keep the file: opening a stroke later pulls its stills from the video.
                if let old = match?.video { try? FileManager.default.removeItem(at: old) }
                let analyzed = try await VideoAnalyzer.analyzeMatch(url: video.url, hand: hand, progress: report)
                if analyzed.report.strokes.isEmpty {
                    error = "No strokes found. Film from the side with your whole body in frame, and keep the camera still."
                } else {
                    app.record(analyzed, hand: hand)
                    match = analyzed
                }
            } else {
                defer { try? FileManager.default.removeItem(at: video.url) }
                let analyzed = try await VideoAnalyzer.analyzeStroke(url: video.url, hand: hand, type: StrokeType(rawValue: strokeType), progress: report)
                if let analyzed {
                    app.record(analyzed, hand: hand)
                    stroke = analyzed
                } else {
                    error = "No stroke found. Make sure your whole body is visible and the clip includes the whole swing."
                }
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
