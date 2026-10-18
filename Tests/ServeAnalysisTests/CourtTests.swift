import XCTest
@testable import ServeAnalysis

final class CourtTests: XCTestCase {
    /// A court seen in perspective: the far baseline is shorter and higher in the image.
    private let taps: [(x: Double, y: Double)] = [(0.2, 0.8), (0.8, 0.8), (0.65, 0.4), (0.35, 0.4)]

    private func assertNear(_ a: (x: Double, y: Double)?, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil", file: file, line: line) }
        XCTAssertEqual(a.x, x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.y, y, accuracy: 1e-6, file: file, line: line)
    }

    func testCalibrationMapsCornersAndCentre() throws {
        let court = try XCTUnwrap(Court.calibrate(taps))
        for (t, c) in zip(taps, Court.corners) { assertNear(court.map(t.x, t.y), c.x, c.y) }
        // The diagonals cross at the centre of the court, even in perspective.
        assertNear(court.map(0.5, 0.8 - 0.4 * 2 / 3), Court.width / 2, Court.net)
        // A crossed (bow-tie) order is rejected.
        XCTAssertNil(Court.calibrate([taps[0], taps[2], taps[1], taps[3]]))
    }

    func testDepthAndInOut() {
        XCTAssertEqual(Bounce(time: 0, x: 4, y: 15).depth, .short)
        XCTAssertEqual(Bounce(time: 0, x: 4, y: 19.5).depth, .mid)
        XCTAssertEqual(Bounce(time: 0, x: 4, y: 22).depth, .deep)
        XCTAssertTrue(Bounce(time: 0, x: Court.width + 0.04, y: 20).isIn) // on the line
        XCTAssertTrue(Bounce(time: 0, x: 4, y: 24.2).long)
        XCTAssertTrue(Bounce(time: 0, x: -0.5, y: 20).wide)
    }

    /// Five sightings around a bounce at image point (`x`, `y`) at `t`, travelling right.
    private func bounce(at t: Double, _ x: Double, _ y: Double) -> [BallSighting] {
        [-0.03, -0.015, 0, -0.01, -0.02].enumerated().map { i, dy in
            BallSighting(time: t + Double(i - 2) / 30, x: x + Double(i - 2) * 0.005, y: y + dy)
        }
    }

    func testFindsBouncesButNotHits() {
        XCTAssertEqual(CourtAnalysis.bounces(bounce(at: 1, 0.5, 0.6)).count, 1)
        // The same shape with the ball reversing across the frame is a hit, not a bounce.
        let hit = [-0.03, -0.015, 0, -0.01, -0.02].enumerated().map { i, dy in
            BallSighting(time: 1 + Double(i - 2) / 30, x: 0.5 - Double(abs(i - 2)) * 0.01, y: 0.6 + dy)
        }
        XCTAssertTrue(CourtAnalysis.bounces(hit).isEmpty)
    }

    func testPlacementOfYourShots() throws {
        let court = try XCTUnwrap(Court.calibrate(taps))
        let toImage = try XCTUnwrap(Homography.fit(from: Court.corners, to: taps))
        let spots: [(Double, Double)] = [(4, 22), (4, 25), (9.5, 18), (2, 15)]
        let sightings = spots.enumerated().flatMap { i, s in
            let p = toImage.map(s.0, s.1)!
            return bounce(at: Double(i) + 1, p.x, p.y)
        }
        let p = CourtAnalysis.placement(sightings, court: court, playerSpots: [toImage.map(4, 2)!])
        XCTAssertEqual(p.yours.count, 4)
        XCTAssertTrue(p.theirs.isEmpty)
        XCTAssertEqual(p.inRate, 0.5)
        XCTAssertEqual(p.long, 1)
        XCTAssertEqual(p.wide, 1)
        XCTAssertEqual(p.depthRate(.deep), 0.5)
        let tip = try XCTUnwrap(p.tip)
        XCTAssertTrue(tip.contains("long") || tip.contains("wide"))
    }
}

final class WristTests: XCTestCase {
    /// 100 Hz wrist motion: three swings (15, 20, 12 rad/s), one with a double peak, and a gentle 4 rad/s wave.
    private func samples() -> [MotionSample] {
        let bumps: [(t: Double, peak: Double)] = [(1, 15), (1.15, 14), (3, 20), (5, 12), (7, 4)]
        return (0..<900).map { i in
            let t = Double(i) / 100
            let w = 0.5 + bumps.map { $0.peak * exp(-pow((t - $0.t) / 0.04, 2)) }.reduce(0, +)
            return MotionSample(time: t, ax: 0, ay: 0, az: 1 + w / 10, gx: w * 0.6, gy: w * 0.8, gz: 0)
        }
    }

    func testDetectsSwingsOnce() throws {
        let detector = WristSwingDetector()
        let swings = samples().compactMap { detector.add($0) }
        XCTAssertEqual(swings.map { ($0.time * 10).rounded() / 10 }, [1, 3, 5])
        XCTAssertEqual(swings[1].peakRotation, 20.5 * 180 / .pi, accuracy: 1)
        XCTAssertGreaterThan(swings[1].peakAcceleration, 2.5)

        let summary = WatchSummary.of(swings, seconds: 600, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(summary.swings, 3)
        XCTAssertEqual(summary.perMinute, 0.3, accuracy: 1e-9)
        XCTAssertEqual(summary.racketSpeed, 20.5 * 0.9, accuracy: 0.1)
        XCTAssertEqual(summary.verdict, "Fairly even swing speed")

        let record = PracticeRecord(watch: summary, hand: .right)
        XCTAssertEqual(record.title, "Watch session")
        XCTAssertEqual(record.detail, "3 swings in 10 min · fastest ≈ 1,175°/s · Fairly even swing speed")
        XCTAssertNil(record.score)
    }
}
