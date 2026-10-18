import ServeAnalysis
import SwiftUI

/// A completed stroke with stills of its key moments, kept together for review and AI coaching.
struct ReviewedStroke: Identifiable {
    let id = UUID()
    let result: StrokeResult
    let images: [Phase: UIImage]
    let samples: [Phase: PoseSample]
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

    private var report: CoachReport? { app.reports[stroke.id] }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(stroke.result.keyFrames, id: \.phase) { key in
                        keyFrame(key.phase.title, image: stroke.images[key.phase], sample: stroke.samples[key.phase])
                    }
                }

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

    @ViewBuilder
    private func keyFrame(_ title: String, image: UIImage?, sample: PoseSample?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                    SkeletonOverlay(sample: sample, fill: false)
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
