import XCTest
@testable import ServeAnalysis

/// Build a pose in pixel space; unspecified joints get a neutral standing position.
func makePose(_ overrides: [Joint: (Double, Double)] = [:]) -> Pose {
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

let goodTrophy = makePose([
    .leftShoulder: (330, 150), .leftElbow: (340, 80), .leftWrist: (350, 10),
    .rightShoulder: (270, 175), .rightElbow: (210, 170), .rightWrist: (210, 110),
    .leftKnee: (340, 370), .rightKnee: (300, 370),
])

let goodContact = makePose([
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

final class CoachTests: XCTestCase {
    private func badTrophyServe() -> ServeResult {
        let pose = makePose([.leftElbow: (340, 80), .leftWrist: (350, 10), .rightElbow: (250, 230), .rightWrist: (240, 300)])
        return ServeAnalyzer.analyze([Frame(time: 0, pose: pose), Frame(time: 1, pose: goodContact)], hand: .right)
    }

    func testRuleBasedPlanPrioritisesFailures() {
        let report = Coach.ruleBased(badTrophyServe(), hand: .right)
        XCTAssertEqual(report.source, .rules)
        XCTAssertFalse(report.improvements.isEmpty)
        XCTAssertLessThanOrEqual(report.improvements.count, 3)
        XCTAssertEqual(report.improvements.first?.title, "Hitting elbow ~90°")
        XCTAssertFalse(report.strengths.isEmpty)
    }

    func testPromptListsChecksAndDrills() {
        let prompt = Coach.prompt(badTrophyServe(), hand: .right, hasImages: true)
        XCTAssertTrue(prompt.contains("[hit-elbow-bend]"))
        XCTAssertTrue(prompt.contains("target 70–115°"))
        XCTAssertTrue(prompt.contains("The images show the serve in order: trophy position, contact."))
        XCTAssertTrue(prompt.contains("Suggested drills"))
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(Coach.schema.utf8)))
    }

    func testParsesModelReplyAndDropsUnknownChecks() throws {
        let reply = """
        Here you go:
        ```json
        {"summary":"Good base.","measurement_review":[{"check_id":"id knee-bend","trustworthy":false,"note":"Legs blurry."},
        {"check_id":"made-up","trustworthy":true,"note":"x"}],"strengths":["Tall at contact"],
        "improvements":[{"title":"Elbow up","why":"Power","how":"Lift the elbow","drill":"Mirror work"},
        {"title":"A","why":"b","how":"c","drill":"d"},{"title":"B","why":"b","how":"c","drill":"d"},
        {"title":"C","why":"b","how":"c","drill":"d"}],"next_session_focus":"Elbow height"}
        ```
        """
        let report = try XCTUnwrap(Coach.parse(reply, result: badTrophyServe(), hand: .right, modelName: "Test"))
        XCTAssertEqual(report.source, .onDeviceAI)
        XCTAssertEqual(report.measurementReview.map(\.checkId), ["knee-bend"])
        XCTAssertEqual(report.distrustedChecks, ["knee-bend"])
        XCTAssertEqual(report.improvements.count, 3)
        XCTAssertEqual(report.modelName, "Test")
    }

    func testFillsBlankFieldsFromThePlanAndStripsCuePrefix() throws {
        let reply = """
        {"summary":"Nice work overall on this serve.","measurement_review":[{"check_id":"[knee-bend]","trustworthy":false,"note":"Low confidence."}],
        "strengths":[],"improvements":[{"title":"Elbow","why":"","how":"Cue: Make an L.","drill":""}],"next_session_focus":""}
        """
        let report = try XCTUnwrap(Coach.parse(reply, result: badTrophyServe(), hand: .right, modelName: "Test"))
        XCTAssertEqual(report.improvements.count, 1)
        XCTAssertEqual(report.improvements.first?.how, "Make an L.")
        XCTAssertEqual(report.improvements.first?.drill, Coach.ruleBased(badTrophyServe(), hand: .right).improvements.first?.drill)
        XCTAssertEqual(report.distrustedChecks, ["knee-bend"])
    }

    func testRejectsJsonStuffedIntoSummary() {
        XCTAssertNil(Coach.parse(#"{"summary":"{\"Player\": \"x\"}","improvements":[]}"#, result: badTrophyServe(), hand: .right, modelName: "Test"))
    }

    func testConfidenceLabelsUseTheCheckedJoints() {
        var pose = makePose()
        pose.joints[.leftKnee]?.confidence = 0.35
        XCTAssertEqual(Coach.confidenceLabel(pose, checkId: "knee-bend", hand: .right), "low")
        XCTAssertEqual(Coach.confidenceLabel(pose, checkId: "hit-elbow-bend", hand: .right), "high")
    }

    func testLowConfidenceChecksAreAlwaysFlagged() throws {
        var trophy = makePose([.leftElbow: (340, 80), .leftWrist: (350, 10), .rightElbow: (250, 230), .rightWrist: (240, 300)])
        for j in [Joint.leftKnee, .rightKnee] { trophy.joints[j]?.confidence = 0.35 }
        let serve = ServeAnalyzer.analyze([Frame(time: 0, pose: trophy), Frame(time: 1, pose: goodContact)], hand: .right)
        XCTAssertEqual(Coach.ruleBased(serve, hand: .right).distrustedChecks, ["knee-bend"])

        // The model calls it trustworthy, misspells another id and repeats the drill in the cue.
        let reply = """
        {"summary":"Work on the elbow and knees.","measurement_review":[{"check_id":"knee_bend","trustworthy":true,"note":"Fine."},
        {"check_id":"hit_elbow_bend","trustworthy":false,"note":"Arm hidden."}],"strengths":["Good toss"],
        "improvements":[{"title":"Elbow","why":"Power.","how":"Make an L. Drill: hold it for 3 seconds.","drill":"Hold the L."}],"next_session_focus":"Elbow"}
        """
        let report = try XCTUnwrap(Coach.parse(reply, result: serve, hand: .right, modelName: "Test"))
        XCTAssertEqual(report.distrustedChecks, ["knee-bend", "hit-elbow-bend"])
        XCTAssertEqual(report.improvements.first?.how, "Make an L.")
    }

    func testRejectsGarbage() {
        XCTAssertNil(Coach.parse("I can't help with that.", result: badTrophyServe(), hand: .right, modelName: "Test"))
        XCTAssertNil(Coach.parse("{\"summary\": \"\", \"improvements\": []}", result: badTrophyServe(), hand: .right, modelName: "Test"))
    }
}

final class HistoryTests: XCTestCase {
    private func record(score: Int?, fix: String? = nil) -> PracticeRecord {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-01-01T00:00:00Z","kind":"forehand","score":\(score.map(String.init) ?? "null"),
        "detail":"","topFix":\(fix.map { "\"\($0)\"" } ?? "null"),"handedness":"right"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(PracticeRecord.self, from: Data(json.utf8))
    }

    func testStorePersistsNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let store = HistoryStore(url: url)
        let serve = ServeAnalyzer.analyze([Frame(time: 0, pose: goodTrophy), Frame(time: 1, pose: goodContact)], hand: .right)
        let first = PracticeRecord(stroke: serve.stroke, hand: .right)
        let second = PracticeRecord(match: MatchAnalyzer.analyze([], hand: .right), hand: .right)
        try store.add(first)
        try store.add(second)
        let reloaded = HistoryStore(url: url).records
        XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.last?.kind, "serve")
        XCTAssertEqual(reloaded.last?.detail, "Trophy position 100 · Contact 100")
        XCTAssertEqual(reloaded.first?.title, "Match")
        try store.clear()
        XCTAssertTrue(HistoryStore(url: url).records.isEmpty)
    }

    func testTrendAndCommonFix() {
        let records = [90, 90, 90, 90, 90, 70, 70, 70, 70, 70].map { record(score: $0, fix: "Knees loaded") }
            + [record(score: nil, fix: "Hitting elbow ~90°")]
        XCTAssertEqual(HistoryStats.trend(records), 20)
        XCTAssertNil(HistoryStats.trend(Array(records.prefix(6))))
        XCTAssertEqual(HistoryStats.mostCommonFix(records), "Knees loaded")
    }
}
