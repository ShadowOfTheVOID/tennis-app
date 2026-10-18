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
            reviewing = await VideoAnalyzer.stills(url: match.video, result: stroke, samples: match.samples)
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
