import ServeAnalysis
import SwiftUI

/// Everything from a match video: stroke breakdown, footwork, AI match plan, and every stroke to review.
struct MatchView: View {
    let match: AnalyzedMatch
    let hand: Handedness

    @Environment(AppState.self) private var app
    @State private var opening: Double?
    @State private var reviewing: ReviewedStroke?

    private var report: MatchReport { match.report }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.countsText).font(.headline)
                        Text(String(format: "%d:%02d of video", Int(report.duration) / 60, Int(report.duration) % 60))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ScoreBadge(score: report.score)
                }
            }

            Section {
                ForEach(report.summaries) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(s.type.title) × \(s.count)").fontWeight(.semibold)
                            if let fix = s.commonFix { Text("Most often missed: \(fix.label)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        ScoreBadge(score: s.averageScore)
                    }
                }
            } header: {
                Text("Strokes")
            } footer: {
                Text("Stroke types are detected from body position and can occasionally be wrong.")
            }

            Section("Footwork (estimated)") {
                if let rate = report.splitStepRate { stat("Split step before the shot", percent(rate), good: rate >= 0.7) }
                if let rate = report.readyStanceRate { stat("Knees bent between shots", percent(rate), good: rate >= 0.7) }
                if let m = report.movementMeters, m >= 1 { stat("Side-to-side movement", "≈ \(Int(m.rounded())) m", good: nil) }
                if report.splitStepRate == nil && report.readyStanceRate == nil {
                    Text("Not enough of your feet were visible to judge footwork.").font(.caption)
                }
            }

            BallSection(match: match, hand: hand)

            Section {
                if let coach = app.reports[match.id] {
                    CoachReportView(report: coach, score: report.score, labels: [:])
                        .listRowInsets(EdgeInsets())
                } else {
                    CoachButton(id: match.id, photos: false) { app.requestCoaching(match, hand: hand) }
                }
            }

            Section("Every stroke") {
                ForEach(Array(report.strokes.enumerated()), id: \.offset) { _, stroke in
                    Button {
                        open(stroke)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "%d:%02d  ", Int(stroke.time) / 60, Int(stroke.time) % 60) + stroke.title)
                                    .fontWeight(.semibold)
                                if let tip = stroke.topTip { Text("Fix: \(tip.label)").font(.caption).foregroundStyle(.secondary) }
                                if stroke.splitStep == false { Text("No split step seen").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if opening == stroke.time { ProgressView() } else { ScoreBadge(score: stroke.score) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(opening != nil)
                }
            }
        }
        .navigationTitle("Match report")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $reviewing) { StrokeReviewView(stroke: $0, hand: hand) }
    }

    private func open(_ stroke: StrokeResult) {
        opening = stroke.time
        Task {
            reviewing = await VideoAnalyzer.stills(url: match.video, result: stroke, samples: match.samples, balls: match.balls, hand: hand)
            opening = nil
        }
    }

    private func percent(_ rate: Double) -> String { "\(Int((rate * 100).rounded()))%" }

    private func stat(_ label: String, _ value: String, good: Bool?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(good.map { $0 ? Color.green : Color.orange } ?? Color.primary)
        }
    }
}

/// Rallies and toss consistency from ball tracking, which is approximate.
private struct BallSection: View {
    let match: AnalyzedMatch
    let hand: Handedness

    var body: some View {
        let rallies = match.rallies
        let tosses = match.tosses(hand: hand)
        Section {
            if !rallies.isEmpty {
                let average = Double(rallies.map(\.shots).reduce(0, +)) / Double(rallies.count)
                Text(String(format: "%d rallies seen, about %.1f shots each, longest %d", rallies.count, average, rallies.map(\.shots).max() ?? 0))
            }
            if let c = BallAnalysis.consistency(tosses) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.verdict).fontWeight(.semibold)
                    Text(String(format: "Over %d serves your toss peaked %.1f torso lengths above your head and %.1f in front of your shoulder, on average.",
                                c.count, c.average.height, c.average.forward))
                    Text(c.average.tip).font(.caption)
                }
            } else if let first = tosses.first {
                Text(first.tip)
            }
            if rallies.isEmpty && tosses.isEmpty {
                Text("The ball wasn't tracked clearly enough. It works best in good light, with the ball against a darker background.")
            }
        } header: {
            Text("Ball tracking (approximate)")
        } footer: {
            Text("The ball blurs at speed, so fast shots are often missed and counts are estimates.")
        }
    }
}
