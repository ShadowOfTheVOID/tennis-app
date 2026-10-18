import Foundation

/// What a shared clip shows and when: slow motion, then a short hold on the last frame. Mirrors `ShareClip` on Android.
public enum ShareClip {
    public static let fps = 30
    public static let slowdown = 4.0
    /// Seconds to hold the last frame so the scores can be read.
    public static let hold = 1.5

    /// For each video frame, the index into `times` (source frame times, oldest first) to show.
    public static func frames(_ times: [Double], fps: Int = fps, slowdown: Double = slowdown, hold: Double = hold) -> [Int] {
        guard let first = times.first, let last = times.last else { return [] }
        let count = Int(((last - first) * slowdown * Double(fps) + 1e-9).rounded(.down)) + 1
        var out: [Int] = []
        var index = 0
        for i in 0..<count {
            let t = first + Double(i) / Double(fps) / slowdown
            while index + 1 < times.count, times[index + 1] <= t + 1e-9 { index += 1 }
            out.append(index)
        }
        out += Array(repeating: times.count - 1, count: Int(hold * Double(fps)))
        return out
    }

    public static func title(_ result: StrokeResult) -> String {
        result.score.map { "\(result.title) · \($0)/100" } ?? result.title
    }

    /// The latest key moment reached by `time`, with its score, e.g. "Contact 80".
    public static func caption(_ result: StrokeResult, time: Double) -> String? {
        guard let key = result.keyFrames.filter({ $0.frame.time <= time + 0.02 }).max(by: { $0.frame.time < $1.frame.time })
        else { return nil }
        guard let score = result.evaluations.first(where: { $0.phase == key.phase })?.score else { return key.phase.title }
        return "\(key.phase.title) \(score)"
    }

    public static func footer(_ result: StrokeResult) -> String {
        result.topTip.map { "Work on: \($0.label)" } ?? "Every check passed"
    }
}
