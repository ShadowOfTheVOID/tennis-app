import ServeAnalysis
import SwiftUI

/// A completed stroke with stills of its key moments, kept together for review and AI coaching.
struct ReviewedStroke: Identifiable {
    let id = UUID()
    let result: StrokeResult
    let images: [Phase: UIImage]
    let samples: [Phase: PoseSample]
    /// Frames around the stroke for the slow-motion replay, oldest first.
    var replay: [ReplayFrame] = []

    /// The time window the replay covers: from just before the first key moment to just after the last.
    static func replayWindow(_ result: StrokeResult) -> ClosedRange<Double>? {
        let times = result.keyFrames.map(\.frame.time)
        guard let first = times.min(), let last = times.max() else { return nil }
        return (first - 0.3)...(last + 0.3)
    }
}

struct ReplayFrame {
    let time: Double
    let image: UIImage
    let sample: PoseSample?
}

extension ReviewedStroke: Hashable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Shows a stroke's key frames and on-device checks, and asks the AI coach how to improve.
struct StrokeReviewView: View {
    let stroke: ReviewedStroke
    let hand: Handedness

    @Environment(AppState.self) private var app
    @State private var showGhost = false

    private var report: CoachReport? { app.reports[stroke.id] }

    var body: some View {
        // "Compare with your best": a ghost of your best-scoring stroke of the same kind.
        let best = app.best(for: stroke)
        ScrollView {
            VStack(spacing: 16) {
                StrokeStats(result: stroke.result)

                if let best, let score = best.score {
                    Toggle("Compare with your best (\(score)/100)", isOn: $showGhost)
                }
                HStack(spacing: 8) {
                    ForEach(stroke.result.keyFrames, id: \.phase) { key in
                        let sample = stroke.samples[key.phase]
                        keyFrame(key.phase.title, image: stroke.images[key.phase], sample: sample,
                                 ghost: showGhost ? ghost(best, phase: key.phase, over: sample) : nil)
                    }
                }
                if showGhost, best != nil {
                    Text("White: this stroke. Grey: your best. Lined up at the hips.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if stroke.replay.count >= 2 { ReplayView(frames: stroke.replay) }

                if let report {
                    CoachReportView(report: report, score: stroke.result.score, labels: labels)
                } else {
                    CoachButton(id: stroke.id, photos: true) { app.requestCoaching(stroke, hand: hand) }
                }

                let distrusted = report?.distrustedChecks ?? []
                ForEach(stroke.result.evaluations, id: \.phase) { EvaluationCard(evaluation: $0, distrusted: distrusted) }
            }
            .padding()
        }
        .navigationTitle(stroke.result.title)
    }

    private var labels: [String: String] {
        Dictionary(stroke.result.checks.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
    }

    private func ghost(_ best: PracticeRecord?, phase: Phase, over sample: PoseSample?) -> PoseSample? {
        guard let best, let sample, let pose = best.pose(at: phase),
              let aligned = PoseAlignment.align(pose, ghostDirection: best.direction ?? 1, to: sample.pose,
                                                targetDirection: stroke.result.direction)
        else { return nil }
        return PoseSample(pose: aligned, imageSize: sample.imageSize)
    }

    @ViewBuilder
    private func keyFrame(_ title: String, image: UIImage?, sample: PoseSample?, ghost: PoseSample?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                    if let ghost { SkeletonOverlay(sample: ghost, fill: false, color: Color(white: 0.85).opacity(0.7)) }
                    SkeletonOverlay(sample: sample, fill: false, color: ghost == nil ? .green : .white)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title).font(.caption.weight(.semibold))
        }
    }
}

/// Estimated hand speed and, for serves, the trophy-to-contact rhythm.
struct StrokeStats: View {
    let result: StrokeResult

    var body: some View {
        if result.swingSpeed != nil || result.tempo != nil {
            HStack(spacing: 8) {
                if let speed = result.swingSpeed {
                    chip("Hand speed", String(format: "≈ %.1f m/s (%d km/h)", speed, Int((speed * 3.6).rounded())))
                }
                if let tempo = result.tempo { chip("Rhythm", String(format: "%.2f s trophy → contact", tempo)) }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2)
            Text(value).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Frame-by-frame replay with the skeleton, scrubbed with a slider or played at quarter speed.
struct ReplayView: View {
    let frames: [ReplayFrame]
    @State private var index = 0
    @State private var playing = false

    var body: some View {
        let frame = frames[min(index, frames.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            Text("Slow-motion replay").font(.headline)
            ZStack {
                Color.black
                Image(uiImage: frame.image).resizable().scaledToFit()
                SkeletonOverlay(sample: frame.sample, fill: false)
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(playing ? "Pause" : "Play at quarter speed")
                Slider(value: Binding(get: { Double(index) }, set: { playing = false; index = Int($0.rounded()) }),
                       in: 0...Double(frames.count - 1), step: 1)
            }
            Text(String(format: "%+.2f s from the first frame · frame %d of %d", frame.time - frames[0].time, index + 1, frames.count))
                .font(.caption)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task(id: playing) {
            while playing {
                let gap = index + 1 < frames.count ? frames[index + 1].time - frames[index].time : 0.1
                try? await Task.sleep(for: .seconds(min(max(gap * 4, 0.04), 1))) // quarter speed
                guard playing else { break }
                if index + 1 < frames.count { index += 1 } else { index = 0; playing = false }
            }
        }
    }
}

/// "How do I improve?" with progress and a note on which coach will answer.
struct CoachButton: View {
    let id: UUID
    /// Whether this review comes with photos the AI could look at.
    let photos: Bool
    let action: () -> Void

    @Environment(AppState.self) private var app

    var body: some View {
        let loading = app.coaching.contains(id)
        VStack(spacing: 8) {
            Button(action: action) {
                Label(loading ? "Coach is reviewing…" : "How do I improve?", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading)
            if loading {
                ProgressView()
                if case .downloaded = app.coachEngine {
                    Text("This takes 1–2 minutes on most phones.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(engineDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var engineDescription: String {
        switch app.coachEngine {
        case .downloaded(let model) where model.vision && photos:
            "\(model.name) runs on your phone and checks the measurements against your photos. Nothing is uploaded."
        case .downloaded(let model):
            "\(model.name) runs on your phone and double-checks the analysis. Nothing is uploaded."
        case .appleIntelligence:
            "Apple Intelligence double-checks the analysis on your phone. Download Gemma 4 in Settings to also check your photos."
        case .rules:
            "Using the built-in coach. Download the free AI model in Settings for personalised, offline AI coaching."
        }
    }
}

struct CoachReportView: View {
    let report: CoachReport
    let score: Int?
    /// Check ids to labels, for the measurement review.
    let labels: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                let ai = report.source == .onDeviceAI
                VStack(alignment: .leading) {
                    Label(ai ? "AI coach" : "Coach", systemImage: ai ? "sparkles" : "list.clipboard").font(.headline)
                    if let name = report.modelName { Text(name).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                ScoreBadge(score: score)
            }
            Text(report.summary)

            if !report.strengths.isEmpty {
                section("What's working")
                ForEach(report.strengths, id: \.self) { s in
                    Label(s, systemImage: "hand.thumbsup.fill").foregroundStyle(.green).font(.subheadline)
                }
            }

            if !report.improvements.isEmpty {
                section("How to improve")
                ForEach(Array(report.improvements.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(item.title)").font(.subheadline.weight(.semibold))
                        Text(item.why).font(.caption).foregroundStyle(.secondary)
                        Text("Cue: \(item.how)").font(.callout)
                        Label(item.drill, systemImage: "figure.tennis").font(.callout).foregroundStyle(.blue)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            section("Next session focus")
            Text(report.nextSessionFocus).font(.callout.weight(.medium))

            if !report.measurementReview.isEmpty {
                DisclosureGroup("Measurement check") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.measurementReview) { review in
                            HStack(alignment: .top) {
                                Image(systemName: review.trustworthy ? "checkmark.seal.fill" : "exclamationmark.bubble.fill")
                                    .foregroundStyle(review.trustworthy ? .green : .orange)
                                VStack(alignment: .leading) {
                                    Text(labels[review.checkId] ?? review.checkId).font(.caption.weight(.semibold))
                                    Text(review.note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
    }
}
