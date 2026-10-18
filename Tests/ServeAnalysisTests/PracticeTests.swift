import XCTest
@testable import ServeAnalysis

final class PracticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A forehand record from `daysAgo`, with contact out in front good or late.
    private func forehand(daysAgo: Double, late: Bool) -> PracticeRecord {
        var keys = groundstroke()
        if late {
            keys[3].1[.rightWrist] = (290, 230)
            keys[3].1[.rightElbow] = arm((280, 160), (290, 230))
        }
        let stroke = StrokeAnalyzer.analyzeClip(sequence(keys, until: 2), type: .forehand, hand: .right)!
        return PracticeRecord(date: now.addingTimeInterval(-daysAgo * 86_400), stroke: stroke, hand: .right)
    }

    func testStrokeRecordKeepsSpeedChecksAndPoses() throws {
        let record = forehand(daysAgo: 0, late: false)
        XCTAssertGreaterThan(try XCTUnwrap(record.swingSpeed), 3)
        XCTAssertEqual(record.direction, 1)
        XCTAssertTrue(record.checks.contains { $0.id == "contact-in-front" && $0.status == "good" })
        XCTAssertEqual(record.pose(at: .contact)?.joints.count, 13)

        // Round-trips through JSON, and old records without the new fields still load.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(PracticeRecord.self, from: encoder.encode(record))
        XCTAssertEqual(back, record)
        let old = #"{"id":"\#(UUID().uuidString)","date":"2026-01-01T00:00:00Z","kind":"serve","score":70,"detail":"","topFix":null,"handedness":"right"}"#
        XCTAssertTrue(try decoder.decode(PracticeRecord.self, from: Data(old.utf8)).checks.isEmpty)
    }

    func testProgressShowsImprovementOverWeeks() throws {
        // Three weeks ago contact was always late; this week it's always in front.
        let records = (0..<3).map { _ in forehand(daysAgo: 1, late: false) } + (0..<3).map { _ in forehand(daysAgo: 22, late: true) }
        let progress = PracticeStats.progress(records, kind: "forehand", now: now)
        let contact = try XCTUnwrap(progress.first { $0.id == "contact-in-front" })
        XCTAssertEqual(contact.weeks.map(\.weeksAgo), [3, 0])
        XCTAssertEqual(contact.summary, "0% good → 100% in 3 weeks")
        XCTAssertEqual(contact.change, 100)
    }

    func testPlanFocusesOnMostMissedCheck() {
        let records = (0..<4).map { _ in forehand(daysAgo: 2, late: true) }
        let plan = PracticePlan.make(records, now: now)
        XCTAssertEqual(plan.focus.first?.checkId, "contact-in-front")
        XCTAssertEqual(plan.days.count, 7)
        XCTAssertTrue(plan.days[0].items.contains { $0.contains("Drop-feed balls") })

        let empty = PracticePlan.make([], now: now)
        XCTAssertTrue(empty.focus.isEmpty)
        XCTAssertEqual(empty.days.first?.title, "Get a baseline")
    }

    func testRhythmAndBest() throws {
        func serve(tempo: Double, score: Int) -> PracticeRecord {
            let json = #"{"id":"\#(UUID().uuidString)","date":"2026-01-01T00:00:00Z","kind":"serve","score":\#(score),"detail":"","handedness":"right","tempo":\#(tempo),"keyPoses":{"contact":{"nose":[1,2,0.9]}}}"#
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try! decoder.decode(PracticeRecord.self, from: Data(json.utf8))
        }
        let steady = try XCTUnwrap(PracticeStats.rhythm([0.50, 0.52, 0.48].map { serve(tempo: $0, score: 70) }))
        XCTAssertEqual(steady.average, 0.5, accuracy: 1e-9)
        XCTAssertEqual(steady.verdict, "Very consistent rhythm")
        XCTAssertEqual(PracticeStats.rhythm([0.3, 0.6, 0.9].map { serve(tempo: $0, score: 70) })?.verdict, "Your rhythm varies a lot")
        XCTAssertNil(PracticeStats.rhythm([serve(tempo: 0.5, score: 70)]))

        let records = [serve(tempo: 0.5, score: 60), serve(tempo: 0.5, score: 90), serve(tempo: 0.5, score: 75)]
        XCTAssertEqual(PracticeStats.best(records, kind: "serve")?.score, 90)
    }

    func testGhostAlignsAndMirrors() throws {
        let target = sequence([(0, [:])], until: 0)[0].pose
        // The ghost is the same stance, twice as big, shifted and facing the other way.
        let ghost = Pose(joints: target.joints.mapValues { Point(x: 1000 - 2 * $0.x, y: 2 * $0.y + 50, confidence: $0.confidence) })
        let aligned = try XCTUnwrap(PoseAlignment.align(ghost, ghostDirection: -1, to: target, targetDirection: 1))
        for (joint, p) in target.joints {
            XCTAssertEqual(aligned.joints[joint]!.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(aligned.joints[joint]!.y, p.y, accuracy: 1e-6)
        }
    }

    func testServeTempoAndFacing() {
        let serve = ServeAnalyzer.analyze([Frame(time: 0.5, pose: goodTrophy), Frame(time: 1.1, pose: goodContact)], hand: .right).stroke
        XCTAssertEqual(try XCTUnwrap(serve.tempo), 0.6, accuracy: 1e-9)
        XCTAssertEqual(serve.direction, 1)
    }

    func testShareClipTimelineAndCaptions() throws {
        let frames = ShareClip.frames([0, 0.1, 0.2])
        XCTAssertEqual(frames.count, 25 + 45) // 0.2 s at quarter speed, 30 fps, plus a 1.5 s hold
        XCTAssertEqual([frames[0], frames[12], frames[24], frames.last!], [0, 1, 2, 2])
        XCTAssertTrue(ShareClip.frames([]).isEmpty)

        let stroke = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(groundstroke(), until: 2), type: .forehand, hand: .right))
        XCTAssertTrue(ShareClip.title(stroke).hasPrefix("Forehand · "))
        let first = stroke.keyFrames.map(\.frame.time).min()!
        XCTAssertNil(ShareClip.caption(stroke, time: first - 0.5))
        let contact = try XCTUnwrap(stroke.keyFrames.first { $0.phase == .contact }).frame.time
        XCTAssertTrue(try XCTUnwrap(ShareClip.caption(stroke, time: contact)).hasPrefix("Contact"))
    }
}
