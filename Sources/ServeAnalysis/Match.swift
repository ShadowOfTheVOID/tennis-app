import Foundation

/// How one kind of stroke went across a match.
public struct StrokeSummary: Sendable, Identifiable {
    public let type: StrokeType
    public let count: Int
    public let averageScore: Int?
    /// The check that most often needed work, if any.
    public let commonFix: Check?
    public var id: StrokeType { type }
}

/// Everything learned from a match or rally video. Mirrors `MatchReport` on Android.
public struct MatchReport: Sendable {
    /// Length of the analysed video, in seconds.
    public let duration: Double
    public let strokes: [StrokeResult]
    /// Points or rallies, split by serves and long pauses.
    public let rallies: Int
    /// Share of your groundstrokes and volleys preceded by a split step (nil if none to judge).
    public let splitStepRate: Double?
    /// Share of the time between shots spent in an athletic stance with knees bent.
    public let readyStanceRate: Double?
    /// Approximate side-to-side distance covered, in metres (movement toward the camera isn't seen).
    public let movementMeters: Double?

    public var summaries: [StrokeSummary] {
        StrokeType.allCases.compactMap { type in
            let group = strokes.filter { $0.type == type }
            guard !group.isEmpty else { return nil }
            let scores = group.compactMap(\.score)
            let fixes = group.compactMap(\.topTip)
            let counts = Dictionary(fixes.map { ($0.id, 1) }, uniquingKeysWith: +)
            let top = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
            return StrokeSummary(
                type: type,
                count: group.count,
                averageScore: scores.isEmpty ? nil : scores.reduce(0, +) / scores.count,
                commonFix: fixes.first { $0.id == top }
            )
        }
    }

    /// "38 strokes in about 9 rallies".
    public var countsText: String {
        "\(strokes.count) stroke\(strokes.count == 1 ? "" : "s") in about \(rallies) rall\(rallies == 1 ? "y" : "ies")"
    }

    /// Average score over every stroke that could be scored.
    public var score: Int? {
        let scores = strokes.compactMap(\.score)
        return scores.isEmpty ? nil : scores.reduce(0, +) / scores.count
    }
}

public enum MatchAnalyzer {
    /// Average adult shoulder-to-hip length, used to turn torso lengths into rough metres.
    static let torsoMeters = 0.5

    /// Find and grade every stroke the player hits in `frames`, plus footwork and movement.
    public static func analyze(_ frames: [Frame], hand: Handedness) -> MatchReport {
        let swings = StrokeAnalyzer.swings(in: frames, hand: hand)
        let scale = StrokeAnalyzer.medianTorso(frames) ?? 1
        var strokes = swings.map { StrokeAnalyzer.analyze(frames, event: $0, hand: hand) }
        for i in strokes.indices where strokes[i].type != .serve {
            strokes[i].splitStep = splitStep(frames, before: strokes[i].time, scale: scale)
        }

        var rallies = 0
        var last = -Double.infinity
        for stroke in strokes {
            if stroke.type == .serve || stroke.time - last > 6 { rallies += 1 }
            last = stroke.time
        }

        let judged = strokes.compactMap(\.splitStep)
        let between = frames.filter { f in !strokes.contains { abs($0.time - f.time) <= 0.8 } }
        let stances = between.compactMap { ServeAnalyzer.kneeAngle($0.pose) }

        return MatchReport(
            duration: (frames.last?.time ?? 0) - (frames.first?.time ?? 0),
            strokes: strokes,
            rallies: rallies,
            splitStepRate: judged.isEmpty ? nil : Double(judged.filter { $0 }.count) / Double(judged.count),
            readyStanceRate: stances.count < 10 ? nil : Double(stances.filter { $0 <= 165 }.count) / Double(stances.count),
            movementMeters: movement(frames, scale: scale)
        )
    }

    /// A split step shows as a small hop: the feet rise briefly in the second or so before the shot.
    static func splitStep(_ frames: [Frame], before t: Double, scale: Double) -> Bool? {
        let window = frames.filter { $0.time >= t - 1.6 && $0.time <= t - 0.3 }.compactMap { f -> Double? in
            guard let l = f.pose[.leftAnkle], let r = f.pose[.rightAnkle] else { return nil }
            return (l.y + r.y) / 2
        }
        guard window.count >= 4 else { return nil }
        let sorted = window.sorted()
        let median = sorted[sorted.count / 2]
        return (median - sorted[0]) / scale >= 0.06
    }

    /// Side-to-side distance covered, ignoring sub-centimetre jitter.
    static func movement(_ frames: [Frame], scale: Double) -> Double? {
        let hips = frames.compactMap { StrokeAnalyzer.hipMid($0.pose) }
        guard hips.count >= 2 else { return nil }
        let steps = zip(hips, hips.dropFirst()).map { Geometry.distance($0, $1) / scale }.filter { $0 > 0.03 }
        return steps.reduce(0, +) * torsoMeters
    }
}
