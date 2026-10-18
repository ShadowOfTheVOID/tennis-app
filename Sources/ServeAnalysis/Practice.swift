import Foundation

// Insights built from practice history: progress per check, serve rhythm, swing speed, the
// weekly practice plan, and lining up a "ghost" of your best stroke. Mirrors Practice.kt.

/// One week's share of a check graded good.
public struct WeekRate: Sendable, Equatable {
    /// 0 = the last 7 days, 1 = the 7 days before that, ...
    public let weeksAgo: Int
    public let goodRate: Double
    public let count: Int
}

/// How one check has gone over recent weeks, oldest week first.
public struct CheckProgress: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let weeks: [WeekRate]

    /// "60% good → 85% in 3 weeks", or just "85% good" with one week of data.
    public var summary: String {
        guard let first = weeks.first, let last = weeks.last else { return "No data yet" }
        let latest = "\(Int((last.goodRate * 100).rounded()))%"
        guard weeks.count > 1 else { return "\(latest) good" }
        let span = first.weeksAgo - last.weeksAgo
        return "\(Int((first.goodRate * 100).rounded()))% good → \(latest) in \(span) week\(span == 1 ? "" : "s")"
    }

    /// Change in good rate from the first week to the latest, in percentage points.
    public var change: Int? {
        guard weeks.count > 1, let first = weeks.first, let last = weeks.last else { return nil }
        return Int(((last.goodRate - first.goodRate) * 100).rounded())
    }
}

/// How consistent the serve's timing from trophy position to contact is.
public struct RhythmStats: Sendable, Equatable {
    public let average: Double
    /// Standard deviation of the tempo, in seconds.
    public let spread: Double
    public let count: Int

    public var verdict: String {
        spread <= 0.08 ? "Very consistent rhythm" : spread <= 0.15 ? "Fairly consistent rhythm" : "Your rhythm varies a lot"
    }

    public var tip: String {
        spread <= 0.15
            ? "Keep the same toss and swing tempo on first and second serves."
            : "Inconsistent rhythm often leads to double faults. Say \"toss… hit\" in the same tempo on every serve."
    }
}

public enum PracticeStats {
    static let week: TimeInterval = 7 * 24 * 3600

    /// Weekly good rate for every check of one kind of stroke, worst latest rate first.
    public static func progress(_ records: [PracticeRecord], kind: String, now: Date = Date(), weeks: Int = 8) -> [CheckProgress] {
        var labels: [String: String] = [:]
        var tallies: [String: [Int: (good: Int, total: Int)]] = [:]
        for record in records where record.kind == kind {
            let weeksAgo = Int(now.timeIntervalSince(record.date) / week)
            guard record.date <= now, weeksAgo < weeks else { continue }
            for check in record.checks where check.status != Status.unknown.rawValue {
                labels[check.id] = check.label
                var t = tallies[check.id, default: [:]][weeksAgo, default: (0, 0)]
                t.total += 1
                if check.status == Status.good.rawValue { t.good += 1 }
                tallies[check.id, default: [:]][weeksAgo] = t
            }
        }
        return tallies.map { id, byWeek in
            CheckProgress(
                id: id,
                label: labels[id] ?? id,
                weeks: byWeek.keys.sorted(by: >).map { w in
                    let t = byWeek[w]!
                    return WeekRate(weeksAgo: w, goodRate: Double(t.good) / Double(t.total), count: t.total)
                }
            )
        }
        .sorted { ($0.weeks.last?.goodRate ?? 0, $0.id) < ($1.weeks.last?.goodRate ?? 0, $1.id) }
    }

    /// Serve rhythm over the most recent serves. Nil until there are at least 3.
    public static func rhythm(_ records: [PracticeRecord], last: Int = 20) -> RhythmStats? {
        let tempos = records.filter { $0.kind == StrokeType.serve.rawValue }.compactMap(\.tempo).prefix(last)
        guard tempos.count >= 3 else { return nil }
        let mean = tempos.reduce(0, +) / Double(tempos.count)
        let variance = tempos.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(tempos.count)
        return RhythmStats(average: mean, spread: variance.squareRoot(), count: tempos.count)
    }

    /// Fastest estimated hand speed per stroke kind, in metres per second.
    public static func topSpeeds(_ records: [PracticeRecord]) -> [String: Double] {
        var best: [String: Double] = [:]
        for r in records where r.kind != PracticeRecord.matchKind {
            if let s = r.swingSpeed { best[r.kind] = max(best[r.kind] ?? 0, s) }
        }
        return best
    }

    /// The best-scoring saved stroke of `kind` that has poses to compare against (the newest on ties).
    public static func best(_ records: [PracticeRecord], kind: String) -> PracticeRecord? {
        records.filter { $0.kind == kind && !$0.keyPoses.isEmpty && $0.score != nil }
            .max { ($0.score ?? 0, $0.date) < ($1.score ?? 0, $1.date) }
    }
}

public enum PoseAlignment {
    /// `ghost` moved and scaled so its hips and torso sit on top of `target`'s, and mirrored when the
    /// two strokes faced opposite ways. Nil if either pose lacks hips and shoulders.
    public static func align(_ ghost: Pose, ghostDirection: Double, to target: Pose, targetDirection: Double) -> Pose? {
        guard let gHip = StrokeAnalyzer.hipMid(ghost), let tHip = StrokeAnalyzer.hipMid(target),
              let gT = ghost.torsoLength, let tT = target.torsoLength else { return nil }
        let scale = tT / gT
        let mirror: Double = ghostDirection * targetDirection < 0 ? -1 : 1
        return Pose(joints: ghost.joints.mapValues { p in
            Point(x: tHip.x + (p.x - gHip.x) * scale * mirror, y: tHip.y + (p.y - gHip.y) * scale, confidence: p.confidence)
        })
    }
}

/// A week of practice built from your most common fixes.
public struct PracticePlan: Sendable {
    public struct Focus: Sendable, Identifiable {
        public let checkId: String
        public let label: String
        /// The stroke kind (a `StrokeType` raw value).
        public let kind: String
        /// Share of recent attempts where this check needed work.
        public let missRate: Double
        public let drill: String
        public var id: String { kind + "/" + checkId }
        public var strokeTitle: String { StrokeType(rawValue: kind)?.title ?? kind }
    }

    public struct Day: Sendable, Identifiable {
        /// 1 to 7.
        public let day: Int
        public let title: String
        public let items: [String]
        public var id: Int { day }
    }

    public let focus: [Focus]
    public let days: [Day]

    /// Build next week's plan from the last 14 days of strokes. Needs at least 3 attempts of a
    /// check before it counts; with too little data it returns a getting-started plan.
    public static func make(_ records: [PracticeRecord], now: Date = Date()) -> PracticePlan {
        var misses: [String: (label: String, kind: String, miss: Int, total: Int)] = [:]
        for record in records where record.kind != PracticeRecord.matchKind && now.timeIntervalSince(record.date) <= 14 * 24 * 3600 {
            for check in record.checks where check.status != Status.unknown.rawValue {
                let key = record.kind + "/" + check.id
                var m = misses[key] ?? (check.label, record.kind, 0, 0)
                m.total += 1
                if check.status != Status.good.rawValue { m.miss += 1 }
                misses[key] = m
            }
        }
        let focus = misses.compactMap { key, m -> Focus? in
            guard m.total >= 3, m.miss > 0 else { return nil }
            let checkId = String(key.split(separator: "/").last ?? "")
            return Focus(checkId: checkId, label: m.label, kind: m.kind, missRate: Double(m.miss) / Double(m.total), drill: Coach.drill(for: checkId))
        }
        .sorted { ($0.missRate, $1.id) > ($1.missRate, $0.id) }
        .prefix(3)

        guard let first = focus.first else {
            return PracticePlan(focus: [], days: [
                Day(day: 1, title: "Get a baseline", items: ["Record 10 serves and 10 forehands on the Live tab."]),
                Day(day: 2, title: "Backhands and volleys", items: ["Record 10 backhands and 10 volleys."]),
                Day(day: 3, title: "Play", items: ["Film a practice set and analyze it in Match mode."]),
                Day(day: 4, title: "Rest", items: ["Rest or stretch. Your personalised plan appears once you've recorded a few strokes."]),
            ])
        }
        let items = Array(focus)
        func work(_ f: Focus) -> [String] {
            ["\(f.strokeTitle): \(f.label.lowercased()) (needed work \(Int((f.missRate * 100).rounded()))% of the time).",
             "Drill: \(f.drill)",
             "Then hit 20 \(f.strokeTitle.lowercased())s thinking only about this."]
        }
        let second = items.count > 1 ? items[1] : first
        let third = items.count > 2 ? items[2] : first
        return PracticePlan(focus: items, days: [
            Day(day: 1, title: "Focus: \(first.label)", items: work(first)),
            Day(day: 2, title: "Focus: \(second.label)", items: work(second)),
            Day(day: 3, title: "Footwork", items: [
                "Drill: \(Coach.drill(for: "split-step"))",
                "Drill: \(Coach.drill(for: "ready-knees"))",
            ]),
            Day(day: 4, title: "Focus: \(third.label)", items: work(third)),
            Day(day: 5, title: "Check your progress", items: work(first) + ["Record 5 strokes in the app to see if the score moved."]),
            Day(day: 6, title: "Play", items: ["Play a practice set and film it. Analyze it in Match mode."]),
            Day(day: 7, title: "Rest", items: ["Rest, stretch your shoulders and hips, and let it sink in."]),
        ])
    }
}
