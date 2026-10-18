import XCTest
@testable import ServeAnalysis

final class BallTests: XCTestCase {
    private let w = 160
    private let h = 120

    /// A court-green frame with a still yellow sign and, optionally, a ball at (`bx`, `by`).
    private func frame(_ time: Double, _ bx: Double?, _ by: Double?) -> RGBImage {
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            guard (0..<w).contains(x), (0..<h).contains(y) else { return }
            let i = 3 * (y * w + x)
            rgb[i] = r; rgb[i + 1] = g; rgb[i + 2] = b
        }
        for y in 0..<h { for x in 0..<w { set(x, y, 60, 140, 70) } }
        for y in 20..<24 { for x in 20..<24 { set(x, y, 220, 230, 40) } }
        if let bx, let by {
            for y in -3...3 { for x in -3...3 where x * x + y * y <= 5 { set(Int(bx) + x, Int(by) + y, 210, 235, 50) } }
        }
        return RGBImage(width: w, height: h, rgb: rgb, time: time)
    }

    func testBallColour() {
        XCTAssertTrue(BallDetector.isBallColour(204, 255, 0))
        XCTAssertTrue(BallDetector.isBallColour(210, 235, 50))
        XCTAssertFalse(BallDetector.isBallColour(60, 140, 70)) // court green
        XCTAssertFalse(BallDetector.isBallColour(224, 172, 105)) // skin
        XCTAssertFalse(BallDetector.isBallColour(240, 240, 240)) // white line
        XCTAssertFalse(BallDetector.isBallColour(190, 90, 50)) // clay
    }

    func testTracksMovingBallAndIgnoresStillYellow() {
        let tracker = BallTracker()
        for i in 0..<12 { tracker.add(frame(Double(i) / 30, 30 + 8 * Double(i), 90 - 4 * Double(i))) }
        let seen = tracker.sightings
        XCTAssertGreaterThanOrEqual(seen.count, 9)
        for s in seen {
            let i = Double(Int((s.time * 30).rounded()))
            XCTAssertEqual(s.x * Double(w), 30 + 8 * i + 0.5, accuracy: 1.5)
            XCTAssertEqual(s.y * Double(h), 90 - 4 * i + 0.5, accuracy: 1.5)
        }
        // Nothing reported near the still sign.
        XCTAssertFalse(seen.contains { abs($0.x * Double(w) - 22) < 4 && abs($0.y * Double(h) - 22) < 4 })
    }

    func testBallAppearingOnlyOnceIsNotReported() {
        let tracker = BallTracker()
        tracker.add(frame(0, nil, nil))
        XCTAssertNil(tracker.add(frame(1.0 / 30, 80, 60)))
        tracker.add(frame(2.0 / 30, nil, nil))
        tracker.add(frame(3.0 / 30, nil, nil))
        XCTAssertTrue(tracker.sightings.isEmpty)
    }

    func testRalliesCountDirectionChanges() {
        // Back and forth across the frame: right, left, right = 3 shots, then a 3 s break and a 2-shot rally.
        let xs = [0.2, 0.4, 0.6, 0.8, 0.6, 0.4, 0.2, 0.4, 0.6, 0.8]
        let first = xs.enumerated().map { BallSighting(time: Double($0.offset) * 0.1, x: $0.element, y: 0.5) }
        let second = [0.8, 0.5, 0.2, 0.5, 0.8].enumerated().map { BallSighting(time: 4 + Double($0.offset) * 0.1, x: $0.element, y: 0.5) }
        XCTAssertEqual(BallAnalysis.rallies(first + second).map(\.shots), [3, 2])
        // Small wobbles aren't shots.
        let wobble = [0.5, 0.55, 0.5, 0.55].enumerated().map { BallSighting(time: Double($0.offset) * 0.1, x: $0.element, y: 0.5) }
        XCTAssertTrue(BallAnalysis.rallies(wobble).isEmpty)
    }

    func testTossPlacementAndConsistency() throws {
        let serve = ServeAnalyzer.analyze([Frame(time: 0.5, pose: goodTrophy), Frame(time: 1.1, pose: goodContact)], hand: .right).stroke
        let torso = try XCTUnwrap(goodTrophy.torsoLength)
        let nose = try XCTUnwrap(goodTrophy[.nose])
        let shoulder = try XCTUnwrap(goodTrophy[.rightShoulder])
        let size = 1000.0
        let apexX = (shoulder.x + 0.5 * torso * serve.direction) / size
        let apexY = (nose.y - 1.2 * torso) / size
        let balls = [BallSighting(time: 0.3, x: apexX, y: apexY + 0.1), BallSighting(time: 0.6, x: apexX, y: apexY),
                     BallSighting(time: 0.9, x: apexX, y: apexY + 0.05)]
        let toss = try XCTUnwrap(BallAnalysis.toss(balls, serve: serve, hand: .right, width: size, height: size))
        XCTAssertEqual(toss.height, 1.2, accuracy: 1e-6)
        XCTAssertEqual(toss.forward, 0.5, accuracy: 1e-6)
        XCTAssertTrue(toss.tip.hasPrefix("Good toss"))
        XCTAssertTrue(TossReading(height: 1.2, forward: -0.3).tip.contains("behind"))

        let c = try XCTUnwrap(BallAnalysis.consistency([TossReading(height: 1.2, forward: 0.5), TossReading(height: 1.3, forward: 0.5),
                                                        TossReading(height: 1.1, forward: 0.5)]))
        XCTAssertEqual(c.verdict, "Very consistent toss")
        XCTAssertNil(BallAnalysis.consistency([toss]))
    }
}
