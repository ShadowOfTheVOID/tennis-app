import XCTest
@testable import ServeAnalysis

// Synthetic side-on swings for a right-hander facing right (the swing moves right).
// The same sequences are used by the Android StrokeTest so both platforms classify identically.

typealias Keys = [Joint: (Double, Double)]

/// Standing body: shoulders y=160, hips y=300 (torso 140 px), athletic stance.
let stance: Keys = [
    .nose: (305, 100),
    .leftShoulder: (320, 160), .rightShoulder: (280, 160),
    .leftHip: (315, 300), .rightHip: (285, 300),
    .leftKnee: (367, 370), .rightKnee: (287, 370),
    .leftAnkle: (360, 440), .rightAnkle: (230, 440),
    .leftElbow: (320, 230), .leftWrist: (330, 260),
    .rightElbow: (290, 230), .rightWrist: (300, 260),
]

/// Linearly interpolate joint positions between keyframes, sampled at `fps`.
func sequence(_ keys: [(Double, Keys)], fps: Double = 15, until end: Double) -> [Frame] {
    stride(from: 0.0, through: end, by: 1 / fps).map { t in
        let after = keys.firstIndex { $0.0 >= t } ?? keys.count - 1
        let before = max(0, after - 1)
        let (t0, a) = keys[before]
        let (t1, b) = keys[after]
        let u = t1 > t0 ? min(1, max(0, (t - t0) / (t1 - t0))) : 1
        var joints: [Joint: Point] = [:]
        for joint in Joint.allCases {
            let p = stance.merging(a) { $1 }[joint]!
            let q = stance.merging(b) { $1 }[joint]!
            joints[joint] = Point(x: p.0 + (q.0 - p.0) * u, y: p.1 + (q.1 - p.1) * u, confidence: 0.9)
        }
        return Frame(time: t, pose: Pose(joints: joints))
    }
}

/// Elbow placed to give a fairly straight arm between shoulder and wrist.
func arm(_ shoulder: (Double, Double), _ wrist: (Double, Double), bend: Double = 10) -> (Double, Double) {
    ((shoulder.0 + wrist.0) / 2, (shoulder.1 + wrist.1) / 2 + bend)
}

/// A forehand (`backhand: false`) or backhand: take-back, fast forward swing to contact at t=1.0s, high finish.
func groundstroke(backhand: Bool = false, twoHanded: Bool = false, contactAt c: Double = 1.0, shift: Double = 0) -> [(Double, Keys)] {
    // Forehand: hitting (right) shoulder turned back; backhand: it's the front shoulder.
    let hs: (Double, Double) = backhand ? (320 + shift, 160) : (280 + shift, 160)
    let ns: (Double, Double) = backhand ? (280 + shift, 160) : (320 + shift, 160)
    func keys(_ wrist: (Double, Double), offArm: (Double, Double)) -> Keys {
        var k: Keys = [.rightShoulder: hs, .leftShoulder: ns, .rightWrist: wrist, .rightElbow: arm(hs, wrist)]
        for (j, v) in stance where j != .rightShoulder && j != .leftShoulder && j != .rightWrist && j != .rightElbow {
            k[j] = (v.0 + shift, v.1)
        }
        let off = twoHanded ? (wrist.0 + 10, wrist.1 + 10) : offArm
        k[.leftWrist] = off
        k[.leftElbow] = arm(ns, off)
        return k
    }
    return [
        (c - 1.0, keys((300 + shift, 260), offArm: (330 + shift, 260))),
        (c - 0.5, keys((300 + shift, 260), offArm: (330 + shift, 260))),
        (c - 0.15, keys((180 + shift, 200), offArm: (360 + shift, 200))),
        (c, keys((360 + shift, 230), offArm: (290 + shift, 260))),
        (c + 0.3, keys((330 + shift, 120), offArm: (290 + shift, 260))),
        (c + 1.0, keys((330 + shift, 120), offArm: (290 + shift, 260))),
    ]
}

final class StrokeTests: XCTestCase {
    private func status(_ r: StrokeResult, _ id: String) -> Status? { r.checks.first { $0.id == id }?.status }

    func testFindsOneSwingPerStroke() {
        let frames = sequence(groundstroke() + groundstroke(contactAt: 3.5), until: 4.5)
        let swings = StrokeAnalyzer.swings(in: frames, hand: .right)
        XCTAssertEqual(swings.count, 2)
        XCTAssertEqual(swings[0].time, 1.0, accuracy: 0.1)
        XCTAssertEqual(swings[1].time, 3.5, accuracy: 0.1)
    }

    func testStandingStillHasNoSwings() {
        XCTAssertTrue(StrokeAnalyzer.swings(in: sequence([(0, [:]), (3, [:])], until: 3), hand: .right).isEmpty)
    }

    func testGoodForehand() throws {
        let r = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(groundstroke(), until: 2), hand: .right))
        XCTAssertEqual(r.type, .forehand)
        XCTAssertEqual(r.keyFrames.map(\.phase), [.preparation, .contact, .finish])
        XCTAssertTrue(r.checks.allSatisfy { $0.status == .good }, "\(r.checks.map { ($0.id, $0.status, $0.value) })")
        XCTAssertEqual(r.score, 100)
    }

    func testBackhandsOneAndTwoHanded() throws {
        let one = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(groundstroke(backhand: true), until: 2), hand: .right))
        XCTAssertEqual(one.type, .backhand)
        XCTAssertFalse(one.twoHanded)
        XCTAssertNotNil(status(one, "contact-spacing"))

        let two = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(groundstroke(backhand: true, twoHanded: true), until: 2), hand: .right))
        XCTAssertEqual(two.type, .backhand)
        XCTAssertTrue(two.twoHanded)
        XCTAssertEqual(two.title, "Two-handed backhand")
        XCTAssertNil(status(two, "contact-spacing"), "arm extension isn't graded on two-handers")
    }

    func testLateContactIsFlagged() throws {
        // Contact beside the body instead of in front.
        var keys = groundstroke()
        keys[3].1[.rightWrist] = (290, 230)
        keys[3].1[.rightElbow] = arm((280, 160), (290, 230))
        let r = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(keys, until: 2), type: .forehand, hand: .right))
        XCTAssertNotEqual(status(r, "contact-in-front"), .good)
    }

    func testVolley() throws {
        let k = { (w: (Double, Double)) -> Keys in [.rightWrist: w, .rightElbow: arm((280, 160), w, bend: 25)] }
        let keys: [(Double, Keys)] = [
            (0, k((300, 220))), (0.7, k((270, 210))), (0.9, k((270, 210))), (1.0, k((370, 215))), (1.4, k((370, 215))), (2, k((370, 215))),
        ]
        let r = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(keys, until: 2), hand: .right))
        XCTAssertEqual(r.type, .volley)
        XCTAssertEqual(status(r, "volley-compact"), .good)
        XCTAssertEqual(status(r, "volley-short"), .good)
    }

    func testServeAndOverheadAreTellApart() throws {
        let trophy: Keys = [
            .leftShoulder: (320, 150), .leftElbow: (330, 80), .leftWrist: (340, 10),
            .rightShoulder: (280, 175), .rightElbow: (220, 170), .rightWrist: (220, 110),
        ]
        let contact: Keys = [.rightShoulder: (285, 150), .rightElbow: (295, 55), .rightWrist: (305, -40), .leftWrist: (310, 220), .leftElbow: (320, 200)]
        let serve = sequence([(0, [:]), (0.6, trophy), (0.9, trophy), (1.0, contact), (1.6, [:])], until: 2)
        XCTAssertEqual(StrokeAnalyzer.analyzeClip(serve, hand: .right)?.type, .serve)

        // Same arm motion, but the player was running back first and never tossed: an overhead.
        func moving(_ dx: Double, _ k: Keys) -> Keys {
            stance.merging(k) { $1 }.mapValues { ($0.0 + dx, $0.1) }
        }
        var noToss = trophy
        noToss[.leftWrist] = (330, 240)
        noToss[.leftElbow] = (325, 200)
        let overhead = sequence([(0, moving(-150, [:])), (0.5, moving(-60, noToss)), (0.9, moving(0, noToss)), (1.0, moving(0, contact)), (1.6, moving(0, [:]))], until: 2)
        let r = try XCTUnwrap(StrokeAnalyzer.analyzeClip(overhead, hand: .right))
        XCTAssertEqual(r.type, .overhead)
        XCTAssertEqual(r.keyFrames.map(\.phase), [.preparation, .contact])
    }

    func testReadyPosition() {
        let good = sequence([(0, [.leftWrist: (330, 250), .rightWrist: (300, 250)])], until: 0)[0].pose
        XCTAssertEqual(StrokeAnalyzer.readyPosition(good).score, 100)
        let lazy = sequence([(0, [.leftKnee: (315, 370), .rightKnee: (285, 370), .leftAnkle: (315, 440), .rightAnkle: (285, 440),
                                  .leftWrist: (320, 330), .rightWrist: (290, 330)])], until: 0)[0].pose
        let e = StrokeAnalyzer.readyPosition(lazy)
        XCTAssertTrue(e.checks.allSatisfy { $0.status == .bad }, "\(e.checks.map { ($0.id, $0.status, $0.value) })")
    }

    func testServeResultBridgesToStroke() {
        let s = ServeResult(trophyFrame: nil, contactFrame: nil, trophy: nil, contact: nil).stroke
        XCTAssertEqual(s.type, .serve)
        XCTAssertNil(s.score)
    }
}
