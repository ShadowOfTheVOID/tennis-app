import Foundation

/// A small RGB image (3 bytes per pixel, row-major) for ball detection.
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: [UInt8]
    public let time: Double

    public init(width: Int, height: Int, rgb: [UInt8], time: Double) {
        self.width = width
        self.height = height
        self.rgb = rgb
        self.time = time
    }
}

/// A ball sighting, as fractions of the image width and height (0–1, y down).
public struct BallSighting: Sendable, Equatable {
    public let time: Double
    public let x: Double
    public let y: Double

    public init(time: Double, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }
}

/// Finds a moving tennis ball: optic-yellow pixels, grouped into small blobs that moved since the
/// previous frame (so yellow signs, shirts standing still and the like are ignored).
/// Mirrors `BallDetector` on Android.
public enum BallDetector {
    struct Blob {
        let x: Double
        let y: Double
        let area: Int
        let moved: Double
    }

    /// Optic yellow: hue 45–95°, fairly saturated and bright.
    public static func isBallColour(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        let hi = max(r, g, b)
        let lo = min(r, g, b)
        if hi < 110 || Double(hi - lo) < 0.35 * Double(hi) { return false }
        let d = Double(hi - lo)
        var hue: Double
        if hi == r {
            hue = 60 * (Double(g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if hi == g {
            hue = 60 * (Double(b - r) / d + 2)
        } else {
            hue = 60 * (Double(r - g) / d + 4)
        }
        if hue < 0 { hue += 360 }
        return (45...95).contains(hue)
    }

    static func blobs(_ image: RGBImage, previous: RGBImage?) -> [Blob] {
        guard let previous, previous.width == image.width, previous.height == image.height else { return [] }
        let w = image.width
        let h = image.height
        let px = image.rgb
        let old = previous.rgb
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { mask[i] = isBallColour(Int(px[3 * i]), Int(px[3 * i + 1]), Int(px[3 * i + 2])) }
        let maxArea = max(12, w * h / 800)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var out: [Blob] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            stack.append(start)
            seen[start] = true
            var area = 0, sx = 0.0, sy = 0.0, moved = 0
            var minX = w, maxX = 0, minY = h, maxY = 0
            while let i = stack.popLast() {
                let x = i % w
                let y = i / w
                area += 1; sx += Double(x); sy += Double(y)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if changed(px, old, i) { moved += 1 }
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            if area < 2 || area > maxArea || moved == 0 { continue }
            // A ball, even motion-blurred, fills a fair part of its bounding box.
            let box = (maxX - minX + 1) * (maxY - minY + 1)
            if Double(area) < 0.3 * Double(box) { continue }
            out.append(Blob(x: (sx / Double(area) + 0.5) / Double(w), y: (sy / Double(area) + 0.5) / Double(h),
                            area: area, moved: Double(moved) / Double(area)))
        }
        return out
    }

    private static func changed(_ a: [UInt8], _ b: [UInt8], _ i: Int) -> Bool {
        var most = 0
        for c in 0..<3 { most = max(most, abs(Int(a[3 * i + c]) - Int(b[3 * i + c]))) }
        return most > 40
    }
}

/// Follows the ball from frame to frame with a constant-velocity guess, and only reports it once
/// it has been seen on three frames in a row that line up. Mirrors `BallTracker` on Android.
public final class BallTracker {
    public static let confirm = 3
    private let maxGap: Double
    private var previous: RGBImage?
    private var track: [BallSighting] = []
    public private(set) var sightings: [BallSighting] = []

    public init(maxGap: Double = 0.3) { self.maxGap = maxGap }

    @discardableResult
    public func add(_ image: RGBImage) -> BallSighting? {
        let blobs = BallDetector.blobs(image, previous: previous)
        previous = image
        if let last = track.last, image.time - last.time > maxGap { track.removeAll() }
        guard let pick = choose(blobs, time: image.time) else {
            if track.count < Self.confirm { track.removeAll() }
            return nil
        }
        track.append(pick)
        if track.count == Self.confirm {
            sightings += track
        } else if track.count > Self.confirm {
            sightings.append(pick)
        } else {
            return nil
        }
        return pick
    }

    private func choose(_ blobs: [BallDetector.Blob], time: Double) -> BallSighting? {
        guard !blobs.isEmpty else { return nil }
        guard let last = track.last else {
            let best = blobs.max { $0.moved * Double($0.area).squareRoot() < $1.moved * Double($1.area).squareRoot() }!
            return BallSighting(time: time, x: best.x, y: best.y)
        }
        var px = last.x
        var py = last.y
        var gate = 0.12
        if track.count >= 2 {
            let before = track[track.count - 2]
            let dt = last.time - before.time
            if dt > 0 {
                let vx = (last.x - before.x) / dt
                let vy = (last.y - before.y) / dt
                px += vx * (time - last.time)
                py += vy * (time - last.time)
                gate = max(gate, hypot(vx, vy) * (time - last.time))
            }
        }
        let best = blobs.min { hypot($0.x - px, $0.y - py) < hypot($1.x - px, $1.y - py) }!
        return hypot(best.x - px, best.y - py) <= gate ? BallSighting(time: time, x: best.x, y: best.y) : nil
    }
}

/// Where the toss peaked, relative to the server, in torso lengths.
public struct TossReading: Sendable, Equatable {
    /// Above the head (nose); positive is higher.
    public let height: Double
    /// In front of the hitting shoulder, toward the court; negative is behind.
    public let forward: Double

    public init(height: Double, forward: Double) {
        self.height = height
        self.forward = forward
    }

    public var tip: String {
        if forward < 0 { return "Your toss drifts behind you. Toss a little more into the court so you can move up into it." }
        if forward > 1.5 { return "Your toss is far in front. Toss closer, about a racket's width in front of your hitting shoulder." }
        if height < 0.8 { return "Toss higher, so the ball peaks above your full reach and you can hit up to it." }
        if height > 2.5 { return "Your toss is very high, which makes timing hard. Toss a little lower." }
        return "Good toss: in front of you and high enough to reach up to."
    }
}

/// How consistent the toss is over several serves.
public struct TossConsistency: Sendable {
    public let average: TossReading
    /// Average distance from the average peak, in torso lengths.
    public let spread: Double
    public let count: Int

    public var verdict: String {
        spread <= 0.25 ? "Very consistent toss" : spread <= 0.5 ? "Fairly consistent toss" : "Your toss moves around a lot"
    }
}

/// A run of play with the ball in sight, and how many times it changed direction (about one per shot).
public struct Rally: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let shots: Int
}

/// Ball-based readings: toss placement for serves, and rallies. Mirrors `BallAnalysis` on Android.
public enum BallAnalysis {
    /// Where the toss peaked for a serve, from ball sightings and the serve's trophy pose.
    /// `width` and `height` are the pose image's size in pixels.
    public static func toss(_ sightings: [BallSighting], serve: StrokeResult, hand: Handedness, width: Double, height: Double) -> TossReading? {
        guard serve.type == .serve, let trophy = serve.frame(for: .trophy), let contact = serve.frame(for: .contact) else { return nil }
        let pose = trophy.pose
        guard let torso = pose.torsoLength, let nose = pose[.nose],
              let shoulder = pose[hand == .right ? .rightShoulder : .leftShoulder] else { return nil }
        let inFlight = sightings.filter { ((trophy.time - 1.2)...contact.time).contains($0.time) }
        guard inFlight.count >= 3, let apex = inFlight.min(by: { $0.y < $1.y }) else { return nil }
        return TossReading(height: (nose.y - apex.y * height) / torso,
                           forward: (apex.x * width - shoulder.x) * serve.direction / torso)
    }

    public static func consistency(_ tosses: [TossReading]) -> TossConsistency? {
        guard tosses.count >= 3 else { return nil }
        let n = Double(tosses.count)
        let h = tosses.map(\.height).reduce(0, +) / n
        let f = tosses.map(\.forward).reduce(0, +) / n
        let spread = tosses.map { hypot($0.height - h, $0.forward - f) }.reduce(0, +) / n
        return TossConsistency(average: TossReading(height: h, forward: f), spread: spread, count: tosses.count)
    }

    /// Splits sightings into rallies (gaps over `maxGap` seconds end one) and counts direction changes
    /// across the frame, each after at least `minTravel` of the frame width.
    public static func rallies(_ sightings: [BallSighting], maxGap: Double = 1.5, minTravel: Double = 0.15) -> [Rally] {
        var out: [Rally] = []
        var i = 0
        while i < sightings.count {
            var j = i
            while j + 1 < sightings.count, sightings[j + 1].time - sightings[j].time <= maxGap { j += 1 }
            let run = sightings[i...j]
            // The first long move is the first shot; every reversal after that is another.
            var shots = 0
            var direction = 0.0
            var extreme = run.first!.x
            for s in run.dropFirst() {
                if direction == 0 {
                    if abs(s.x - extreme) >= minTravel { direction = s.x > extreme ? 1 : -1; shots = 1; extreme = s.x }
                } else if (s.x - extreme) * direction > 0 {
                    extreme = s.x
                } else if (extreme - s.x) * direction >= minTravel {
                    direction = -direction; shots += 1; extreme = s.x
                }
            }
            if shots > 0 { out.append(Rally(start: run.first!.time, end: run.last!.time, shots: shots)) }
            i = j + 1
        }
        return out
    }
}
