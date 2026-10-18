import AVFoundation
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
    /// Pose at each stroke's key moments, for drawing the skeleton.
    let samples: [Double: PoseSample]
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
        let (frames, samples) = try await poses(url: url, fps: strokeFPS, maxSeconds: strokeMaxSeconds, progress: progress)
        guard let result = StrokeAnalyzer.analyzeClip(frames, type: type, hand: hand) else { return nil }
        return await stills(url: url, result: result, samples: samples)
    }

    static func analyzeMatch(url: URL, hand: Handedness, progress: @escaping (Double) -> Void) async throws -> AnalyzedMatch {
        let (frames, samples) = try await poses(url: url, fps: matchFPS, maxSeconds: matchMaxSeconds, progress: progress)
        let report = MatchAnalyzer.analyze(frames, hand: hand)
        // Every analysed frame's pose is kept, so each stroke's replay can show its skeleton.
        return AnalyzedMatch(report: report, video: url, samples: samples)
    }

    /// Pull the stills for one stroke's key moments from the video.
    static func stills(url: URL, result: StrokeResult, samples: [Double: PoseSample]) async -> ReviewedStroke {
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
        return ReviewedStroke(result: result, images: images, samples: poseSamples, replay: replay)
    }

    /// Decode the video in order and detect a pose about `fps` times a second.
    /// Sequential decoding is far faster than seeking to each frame, which matters for long matches.
    private static func poses(url: URL, fps: Double, maxSeconds: Double, progress: @escaping (Double) -> Void) async throws
        -> (frames: [Frame], samples: [Double: PoseSample]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return ([], [:]) }
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
        var next = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time >= next, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            next = time + 1 / fps - 0.005
            if let sample = detector.detect(pixelBuffer: pixels, orientation: orientation) {
                frames.append(Frame(time: time, pose: sample.pose))
                samples[time] = sample
            }
            progress(duration > 0 ? min(1, time / duration) : 1)
        }
        return (frames, samples)
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
