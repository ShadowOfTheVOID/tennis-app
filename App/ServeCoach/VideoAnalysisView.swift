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

enum VideoAnalyzer {
    /// Frames sampled per second of video.
    static let sampleRate = 15.0
    /// Longest stretch of video analysed; one serve takes a couple of seconds.
    static let maxDuration = 20.0

    static func analyze(url: URL, hand: Handedness, progress: @escaping (Double) -> Void) async throws -> ReviewedServe {
        let asset = AVURLAsset(url: url)
        let duration = min(try await asset.load(.duration).seconds, maxDuration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let tolerance = CMTime(seconds: 0.5 / sampleRate, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let detector = PoseDetector()
        var frames: [Frame] = []
        var samples: [Double: PoseSample] = [:]
        let count = max(1, Int(duration * sampleRate))

        for i in 0..<count {
            try Task.checkCancellation()
            let time = Double(i) / sampleRate
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
               let sample = detector.detect(cgImage: image) {
                frames.append(Frame(time: time, pose: sample.pose))
                samples[time] = sample
            }
            progress(Double(i + 1) / Double(count))
        }

        let result = ServeAnalyzer.analyze(frames, hand: hand)

        func still(_ frame: Frame?) async -> UIImage? {
            guard let frame,
                  let image = try? await generator.image(at: CMTime(seconds: frame.time, preferredTimescale: 600)).image
            else { return nil }
            return UIImage(cgImage: image)
        }

        return ReviewedServe(
            result: result,
            trophyImage: await still(result.trophyFrame),
            contactImage: await still(result.contactFrame),
            trophySample: result.trophyFrame.flatMap { samples[$0.time] },
            contactSample: result.contactFrame.flatMap { samples[$0.time] }
        )
    }
}

struct VideoAnalysisView: View {
    @AppStorage("handedness") private var hand: Handedness = .right
    @Environment(AppState.self) private var app
    @State private var item: PhotosPickerItem?
    @State private var progress: Double?
    @State private var serve: ReviewedServe?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let progress {
                    VStack(spacing: 12) {
                        ProgressView(value: progress)
                        Text("Finding your trophy position and contact point…").font(.callout)
                    }
                    .padding()
                } else if let serve {
                    if serve.result.trophyFrame == nil && serve.result.contactFrame == nil {
                        ContentUnavailableView(
                            "No serve found",
                            systemImage: "figure.tennis",
                            description: Text("Make sure your whole body is visible and the clip includes the toss and contact.")
                        )
                    } else {
                        ServeReviewView(serve: serve, hand: hand)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Analyze a serve video", systemImage: "video.badge.waveform")
                    } description: {
                        Text("Film one serve side-on with your whole body in frame, then pick the clip here.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Video")
            .toolbar {
                PhotosPicker(selection: $item, matching: .videos) {
                    Label("Pick video", systemImage: "photo.on.rectangle")
                }
            }
            .alert("Couldn't analyze video", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task(id: item) { await load() }
        }
    }

    private func load() async {
        guard let item else { return }
        serve = nil
        progress = 0
        defer { progress = nil }
        do {
            guard let video = try await item.loadTransferable(type: PickedVideo.self) else { return }
            defer { try? FileManager.default.removeItem(at: video.url) }
            let analyzed = try await VideoAnalyzer.analyze(url: video.url, hand: hand) { value in
                Task { @MainActor in if progress != nil { progress = value } }
            }
            serve = analyzed
            if analyzed.result.trophyFrame != nil || analyzed.result.contactFrame != nil {
                app.record(analyzed, hand: hand)
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
