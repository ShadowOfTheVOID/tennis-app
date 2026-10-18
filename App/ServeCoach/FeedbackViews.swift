import ServeAnalysis
import SwiftUI

extension Status {
    var color: Color {
        switch self {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct ScoreBadge: View {
    let score: Int?

    var body: some View {
        Text(score.map { "\($0)" } ?? "—")
            .font(.title2.bold().monospacedDigit())
            .frame(width: 56, height: 56)
            .background(Circle().fill(color.opacity(0.2)))
            .overlay(Circle().stroke(color, lineWidth: 3))
    }

    private var color: Color {
        guard let score else { return .gray }
        return score >= 80 ? .green : score >= 50 ? .orange : .red
    }
}

struct CheckRow: View {
    let check: Check
    var distrusted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbol)
                .foregroundStyle(check.status.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(check.label).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(check.value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if distrusted {
                    Text("AI coach thinks this measurement may be wrong.").font(.caption).foregroundStyle(.orange)
                }
                if check.status != .good {
                    Text(check.tip).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct EvaluationCard: View {
    let evaluation: Evaluation
    var distrusted: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(evaluation.phase.title).font(.headline)
                Spacer()
                ScoreBadge(score: evaluation.score)
            }
            ForEach(evaluation.checks) { CheckRow(check: $0, distrusted: distrusted.contains($0.id)) }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
