import ServeAnalysis
import SwiftUI

/// A completed serve's key frames, kept together for review and AI coaching.
struct ReviewedServe: Identifiable {
    let id = UUID()
    let result: ServeResult
    let trophyImage: UIImage?
    let contactImage: UIImage?
    let trophySample: PoseSample?
    let contactSample: PoseSample?
}

/// Shows a serve's key frames and on-device checks, and asks the AI coach how to improve.
struct ServeReviewView: View {
    let serve: ReviewedServe
    let hand: Handedness

    @State private var report: CoachReport?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    keyFrame("Trophy", image: serve.trophyImage, sample: serve.trophySample)
                    keyFrame("Contact", image: serve.contactImage, sample: serve.contactSample)
                }

                aiSection

                if let trophy = serve.result.trophy { EvaluationCard(evaluation: trophy) }
                if let contact = serve.result.contact { EvaluationCard(evaluation: contact) }
            }
            .padding()
        }
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

    @ViewBuilder
    private var aiSection: some View {
        if let report {
            CoachReportView(report: report, serve: serve.result)
        } else {
            VStack(spacing: 8) {
                Button {
                    Task { await askCoach() }
                } label: {
                    Label(loading ? "Coach is reviewing your serve…" : "How do I improve?", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
                if loading { ProgressView() }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text(AICoach.unavailableReason.map { "\($0) You'll get the built-in coach instead." }
                    ?? "Apple's on-device AI double-checks the measurements and builds your improvement plan. Nothing leaves your phone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func askCoach() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            report = try await AICoach.review(serve, hand: hand)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CoachReportView: View {
    let report: CoachReport
    let serve: ServeResult

    private var labels: [String: String] {
        let checks = (serve.trophy?.checks ?? []) + (serve.contact?.checks ?? [])
        return Dictionary(checks.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(report.fromAI ? "AI coach" : "Coach", systemImage: report.fromAI ? "sparkles" : "list.clipboard")
                    .font(.headline)
                Spacer()
                ScoreBadge(score: serve.score)
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
