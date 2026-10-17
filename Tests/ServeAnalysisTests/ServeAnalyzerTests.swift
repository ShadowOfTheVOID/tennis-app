import XCTest
@testable import ServeAnalysis

/// Build a pose in pixel space; unspecified joints get a neutral standing position.
private func makePose(_ overrides: [Joint: (Double, Double)] = [:]) -> Pose {
    let base: [Joint: (Double, Double)] = [
        .nose: (300, 100),
        .leftShoulder: (330, 160), .rightShoulder: (270, 160),
        .leftElbow: (340, 220), .rightElbow: (260, 220),
        .leftWrist: (345, 280), .rightWrist: (255, 280),
        .leftHip: (320, 300), .rightHip: (280, 300),
        .leftKnee: (320, 370), .rightKnee: (280, 370),
        .leftAnkle: (320, 440), .rightAnkle: (280, 440),
    ]
    let merged = base.merging(overrides) { $1 }
    return Pose(joints: merged.mapValues { Point(x: $0.0, y: $0.1, confidence: 0.9) })
}

private let goodTrophy = makePose([
    .leftShoulder: (330, 150), .leftElbow: (340, 80), .leftWrist: (350, 10),
    .rightShoulder: (270, 175), .rightElbow: (210, 170), .rightWrist: (210, 110),
    .leftKnee: (340, 370), .rightKnee: (300, 370),
])

private let goodContact = makePose([
    .rightShoulder: (275, 150), .rightElbow: (285, 55), .rightWrist: (295, -40),
    .leftElbow: (340, 190), .leftWrist: (310, 200),
])

private func status(_ e: Evaluation, _ id: String) -> Status? {
    e.checks.first { $0.id == id }?.status
}

/// Mirror a pose horizontally and swap left/right joints (a right-hander becomes a left-hander).
private func mirrored(_ pose: Pose) -> Pose {
    var out: [Joint: Point] = [:]
    for (joint, p) in pose.joints {
        let name = joint.rawValue
        let swapped = name.hasPrefix("left") ? "right" + name.dropFirst(4)
            : name.hasPrefix("right") ? "left" + name.dropFirst(5) : name
        out[Joint(rawValue: swapped)!] = Point(x: 600 - p.x, y: p.y, confidence: p.confidence)
    }
    return Pose(joints: out)
}

final class GeometryTests: XCTestCase {
    func testRightAngle() {
        XCTAssertEqual(Geometry.angle(Point(x: 1, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 1)), 90, accuracy: 1e-9)
    }

    func testStraightLine() {
        XCTAssertEqual(Geometry.angle(Point(x: -1, y: 0), Point(x: 0, y: 0), Point(x: 1, y: 0)), 180, accuracy: 1e-9)
    }
}

final class ServeAnalyzerTests: XCTestCase {
    func testPhaseDetection() {
        XCTAssertEqual(ServeAnalyzer.phase(of: goodTrophy, hand: .right), .trophy)
        XCTAssertEqual(ServeAnalyzer.phase(of: goodContact, hand: .right), .contact)
        XCTAssertEqual(ServeAnalyzer.phase(of: makePose(), hand: .right), .ready)
    }

    func testTextbookTrophyScoresFull() {
        let e = ServeAnalyzer.trophy(goodTrophy, hand: .right)
        XCTAssertTrue(e.checks.allSatisfy { $0.status == .good }, "\(e.checks.map { ($0.id, $0.status, $0.value) })")
        XCTAssertEqual(e.score, 100)
    }

    func testLeftHanderMirrorScoresFull() {
        XCTAssertEqual(ServeAnalyzer.trophy(mirrored(goodTrophy), hand: .left).score, 100)
    }

    func testFlagsStraightHittingArmAndLowElbow() {
        let pose = makePose([.leftElbow: (340, 80), .leftWrist: (350, 10), .rightElbow: (250, 230), .rightWrist: (240, 300)])
        let e = ServeAnalyzer.trophy(pose, hand: .right)
        XCTAssertEqual(status(e, "hit-elbow-bend"), .bad)
        XCTAssertEqual(status(e, "hit-elbow-height"), .bad)
    }

    func testFlagsLockedKnees() {
        let e = ServeAnalyzer.trophy(makePose([.leftWrist: (350, 10)]), hand: .right)
        XCTAssertEqual(status(e, "knee-bend"), .bad)
    }

    func testHiddenLegsAreUnknownAndExcludedFromScore() {
        var pose = goodTrophy
        for j in [Joint.leftKnee, .rightKnee, .leftAnkle, .rightAnkle] { pose.joints[j]?.confidence = 0.1 }
        let e = ServeAnalyzer.trophy(pose, hand: .right)
        XCTAssertEqual(status(e, "knee-bend"), .unknown)
        XCTAssertEqual(e.score, 100)
    }

    func testFullExtensionContact() {
        let e = ServeAnalyzer.contact(goodContact, hand: .right)
        XCTAssertTrue(e.checks.allSatisfy { $0.status == .good }, "\(e.checks.map { ($0.id, $0.status, $0.value) })")
    }

    func testFlagsBentArmAtContact() {
        let e = ServeAnalyzer.contact(makePose([.rightElbow: (250, 90), .rightWrist: (300, 40)]), hand: .right)
        XCTAssertEqual(status(e, "hit-arm-extended"), .bad)
    }

    func testKeyFramesTrophyBeforeContact() {
        let frames = [
            Frame(time: 0, pose: makePose()),
            Frame(time: 0.5, pose: goodTrophy),
            Frame(time: 1, pose: goodContact),
            Frame(time: 1.5, pose: makePose()),
        ]
        let (trophy, contact) = ServeAnalyzer.keyFrames(in: frames, hand: .right)
        XCTAssertEqual(trophy?.time, 0.5)
        XCTAssertEqual(contact?.time, 1)
    }

    func testTrackerReportsServeAfterContact() {
        var tracker = ServeTracker(hand: .right)
        XCTAssertNil(tracker.add(Frame(time: 0, pose: makePose())))
        XCTAssertNil(tracker.add(Frame(time: 0.5, pose: goodTrophy)))
        XCTAssertNil(tracker.add(Frame(time: 1, pose: goodContact)))
        let result = tracker.add(Frame(time: 1.2, pose: makePose()))
        XCTAssertEqual(result?.trophyFrame?.time, 0.5)
        XCTAssertEqual(result?.contactFrame?.time, 1)
        XCTAssertEqual(result?.score, 100)
        XCTAssertNil(result?.topTip)
        // Nothing more until the next contact.
        XCTAssertNil(tracker.add(Frame(time: 1.4, pose: makePose())))
    }

    func testTrackerForgetsFramesOutsideWindow() {
        var tracker = ServeTracker(hand: .right, window: 1)
        _ = tracker.add(Frame(time: 0, pose: goodTrophy))
        _ = tracker.add(Frame(time: 5, pose: goodContact))
        let result = tracker.add(Frame(time: 5.2, pose: makePose()))
        XCTAssertNil(result?.trophyFrame)
        XCTAssertNotNil(result?.contactFrame)
    }
}
