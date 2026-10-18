import Foundation

/// A projective map between two planes, from four point pairs. Mirrors `Homography` on Android.
public struct Homography: Sendable {
    private let h: [Double]
    private let ox: Double
    private let oy: Double

    public func map(_ px: Double, _ py: Double) -> (x: Double, y: Double)? {
        let x = px - ox
        let y = py - oy
        let w = h[6] * x + h[7] * y + 1
        guard abs(w) >= 1e-12 else { return nil }
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// The map taking each of `from` to the matching point of `to`. Nil if the points are degenerate.
    public static func fit(from: [(x: Double, y: Double)], to: [(x: Double, y: Double)]) -> Homography? {
        precondition(from.count == 4 && to.count == 4)
        // Solved about the points' centroid, which lies inside the shape and so is never on the horizon
        // (where the usual normalisation would break down).
        let ox = from.map(\.x).reduce(0, +) / 4
        let oy = from.map(\.y).reduce(0, +) / 4
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = from[i].x - ox
            let y = from[i].y - oy
            let (u, v) = to[i]
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // Gaussian elimination with partial pivoting.
        for col in 0..<8 {
            let pivot = (col..<8).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            guard abs(a[pivot][col]) >= 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<8 where r != col {
                let f = a[r][col] / a[col][col]
                if f != 0 { for c in col...8 { a[r][c] -= f * a[col][c] } }
            }
        }
        return Homography(h: (0..<8).map { a[$0][8] / a[$0][$0] }, ox: ox, oy: oy)
    }
}

/// Singles court in metres: x across (0 to `width`), y along (0 to `length`), net at `net`.
public enum Court {
    public static let width = 8.23
    public static let length = 23.77
    public static let net = length / 2
    /// Service line distance from the net.
    public static let service = 6.40
    /// Lines count as in; this allows for their 5 cm width.
    public static let line = 0.05

    /// The four corners in tap order: both ends of one baseline, then around the court.
    public static let corners: [(x: Double, y: Double)] = [(0, 0), (width, 0), (width, length), (0, length)]

    /// Image-to-court map from the four tapped corners (any image units). Nil if they don't form a convex shape.
    public static func calibrate(_ taps: [(x: Double, y: Double)]) -> Homography? {
        guard taps.count == 4, convex(taps) else { return nil }
        return Homography.fit(from: taps, to: corners)
    }

    static func convex(_ p: [(x: Double, y: Double)]) -> Bool {
        var sign = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if s != sign { return false }
        }
        return true
    }
}

public enum Depth: String, Sendable, CaseIterable {
    case short, mid, deep
    public var title: String {
        switch self {
        case .short: "Short"
        case .mid: "Middle"
        case .deep: "Deep"
        }
    }
}

/// Where a bounce landed, in court metres.
public struct Bounce: Sendable, Equatable {
    public let time: Double
    public let x: Double
    public let y: Double

    public init(time: Double, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }

    public var isIn: Bool { x >= -Court.line && x <= Court.width + Court.line && y >= -Court.line && y <= Court.length + Court.line }
    /// 0 for the half nearer y = 0, 1 for the other.
    public var half: Int { y < Court.net ? 0 : 1 }
    public var long: Bool { y < -Court.line || y > Court.length + Court.line }
    public var wide: Bool { x < -Court.line || x > Court.width + Court.line }
    public var depth: Depth {
        let fromNet = abs(y - Court.net)
        if fromNet <= Court.service { return .short }
        if fromNet >= Court.net - 3 { return .deep }
        return .mid
    }
}

/// Your shots' landing spots, and what they add up to.
public struct Placement: Sendable {
    public let yours: [Bounce]
    public let theirs: [Bounce]

    public var inRate: Double? { yours.isEmpty ? nil : Double(yours.filter(\.isIn).count) / Double(yours.count) }
    public var long: Int { yours.filter(\.long).count }
    public var wide: Int { yours.filter { $0.wide && !$0.long }.count }

    public func depthRate(_ depth: Depth) -> Double? {
        let landed = yours.filter(\.isIn)
        return landed.isEmpty ? nil : Double(landed.filter { $0.depth == depth }.count) / Double(landed.count)
    }

    public var tip: String? {
        guard let rate = inRate else { return nil }
        let deep = depthRate(.deep) ?? 0
        let short = depthRate(.short) ?? 0
        if rate < 0.6 && long > wide { return "Many shots go long. Swing low to high with more topspin, and aim a metre or two inside the baseline." }
        if rate < 0.6 { return "Many shots go wide. Aim further inside the sidelines; go for the lines only on an easy ball." }
        if short > 0.4 { return "Lots of your shots land short, which lets your opponent attack. Aim past the service line, about two metres from the baseline." }
        if deep >= 0.4 { return "Good depth: plenty of your shots land in the last 3 metres." }
        return "Mostly safe, middling depth. Aim a little deeper to push your opponent back."
    }
}

/// Bounces from the ball track, mapped onto the court. Mirrors `CourtAnalysis` on Android.
public enum CourtAnalysis {
    /// Bounces are where the ball, seen as fractions of the image, stops falling and starts rising
    /// while still travelling the same way across the frame (a hit would reverse it).
    public static func bounces(_ sightings: [BallSighting], maxStep: Double = 0.1) -> [BallSighting] {
        var out: [BallSighting] = []
        guard sightings.count >= 5 else { return out }
        for i in 2..<(sightings.count - 2) {
            let w = Array(sightings[(i - 2)...(i + 2)])
            if (1..<w.count).contains(where: { w[$0].time - w[$0 - 1].time > maxStep }) { continue }
            let b = w[2]
            if w.contains(where: { $0.y > b.y }) { continue }
            if b.y - w[0].y < 0.01 || b.y - w[4].y < 0.005 { continue }
            let before = b.x - w[0].x
            let after = w[4].x - b.x
            if before * after < 0 && max(abs(before), abs(after)) > 0.01 { continue }
            if let last = out.last, b.time - last.time < 0.2 { continue }
            out.append(b)
        }
        return out
    }

    /// Your shots land on the other half from where you stand. `playerSpots` are your feet as image
    /// fractions during the match; `court` maps image fractions to court metres.
    public static func placement(_ sightings: [BallSighting], court: Homography, playerSpots: [(x: Double, y: Double)]) -> Placement {
        let halves = playerSpots.compactMap { court.map($0.x, $0.y)?.y }.map { $0 < Court.net ? 0 : 1 }
        let yourHalf = halves.filter { $0 == 1 }.count > halves.count / 2 ? 1 : 0
        let all = bounces(sightings).compactMap { b in court.map(b.x, b.y).map { Bounce(time: b.time, x: $0.x, y: $0.y) } }
            // Anything far off the court is a misreading, not a bounce.
            .filter { (-6...(Court.width + 6)).contains($0.x) && (-8...(Court.length + 8)).contains($0.y) }
        return Placement(yours: all.filter { $0.half != yourHalf }, theirs: all.filter { $0.half == yourHalf })
    }

    /// Midpoint of the ankles, as image fractions, for `placement`.
    public static func feet(_ pose: Pose, width: Double, height: Double) -> (x: Double, y: Double)? {
        guard let l = pose[.leftAnkle], let r = pose[.rightAnkle] else { return nil }
        return ((l.x + r.x) / 2 / width, max(l.y, r.y) / height)
    }
}
