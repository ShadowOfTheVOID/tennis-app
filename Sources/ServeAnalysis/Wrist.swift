import Foundation

/// One reading from a watch: acceleration in g and rotation rate in radians per second, in the watch's axes.
public struct MotionSample: Sendable {
    public let time: Double
    public let ax: Double, ay: Double, az: Double
    public let gx: Double, gy: Double, gz: Double

    public init(time: Double, ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
        self.time = time
        self.ax = ax; self.ay = ay; self.az = az
        self.gx = gx; self.gy = gy; self.gz = gz
    }

    public var rotation: Double { (gx * gx + gy * gy + gz * gz).squareRoot() }
    public var acceleration: Double { (ax * ax + ay * ay + az * az).squareRoot() }
}

/// One swing felt at the wrist.
public struct WristSwing: Sendable, Equatable {
    public let time: Double
    /// Peak wrist rotation, degrees per second.
    public let peakRotation: Double
    /// Peak acceleration, g.
    public let peakAcceleration: Double
}

/// Finds swings in a watch's motion: a burst of wrist rotation over `threshold` rad/s, ended when it
/// falls below half that, with at least `gap` seconds between swings. Mirrors `WristSwingDetector` on Android.
public final class WristSwingDetector {
    private let threshold: Double
    private let gap: Double
    private var inSwing = false
    private var peak = 0.0
    private var peakTime = 0.0
    private var peakAccel = 0.0
    private var lastSwing = -Double.infinity

    public init(threshold: Double = 6.0, gap: Double = 0.7) {
        self.threshold = threshold
        self.gap = gap
    }

    public func add(_ s: MotionSample) -> WristSwing? {
        let w = s.rotation
        if !inSwing {
            guard w >= threshold else { return nil }
            inSwing = true
            peak = w; peakTime = s.time; peakAccel = s.acceleration
            return nil
        }
        if w > peak { peak = w; peakTime = s.time }
        if s.acceleration > peakAccel { peakAccel = s.acceleration }
        guard w < threshold / 2 else { return nil }
        inSwing = false
        guard peakTime - lastSwing >= gap else { return nil }
        lastSwing = peakTime
        return WristSwing(time: peakTime, peakRotation: peak * 180 / .pi, peakAcceleration: peakAccel)
    }
}

/// A watch practice session, small enough to send to the phone. Mirrors `WatchSummary` on Android.
public struct WatchSummary: Codable, Sendable, Equatable {
    public let date: Date
    public let seconds: Double
    public let swings: Int
    /// Fastest and average peak wrist rotation, degrees per second.
    public let best: Double
    public let average: Double
    /// Spread of the peaks relative to their average (0 = identical swings).
    public let spread: Double

    public init(date: Date, seconds: Double, swings: Int, best: Double, average: Double, spread: Double) {
        self.date = date
        self.seconds = seconds
        self.swings = swings
        self.best = best
        self.average = average
        self.spread = spread
    }

    public var perMinute: Double { seconds > 0 ? Double(swings) * 60 / seconds : 0 }

    /// Rough racket-head speed for the fastest swing: wrist rotation × about 0.9 m (forearm and racket), in m/s.
    public var racketSpeed: Double { best * .pi / 180 * 0.9 }

    public var verdict: String {
        if swings < 3 { return "Too few swings to judge consistency" }
        if spread <= 0.15 { return "Very even swing speed" }
        if spread <= 0.3 { return "Fairly even swing speed" }
        return "Swing speed varies a lot: aim for the same smooth acceleration every time"
    }

    public static func of(_ swings: [WristSwing], seconds: Double, date: Date) -> WatchSummary {
        let peaks = swings.map(\.peakRotation)
        let average = peaks.isEmpty ? 0 : peaks.reduce(0, +) / Double(peaks.count)
        let spread = peaks.count < 2 || average == 0 ? 0
            : (peaks.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(peaks.count)).squareRoot() / average
        return WatchSummary(date: date, seconds: seconds, swings: swings.count, best: peaks.max() ?? 0, average: average, spread: spread)
    }
}
