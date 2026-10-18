import XCTest
@testable import ServeAnalysis

final class MatchTests: XCTestCase {
    /// Hops the feet up before a shot (a split step) when `split` is set.
    private func rally(split: Bool) -> [(Double, Keys)] {
        var keys: [(Double, Keys)] = []
        for (i, contact) in [2.0, 5.0, 8.0].enumerated() {
            var strokes = groundstroke(backhand: i == 1, contactAt: contact)
            if split {
                let hop: Keys = [.leftAnkle: (360, 425), .rightAnkle: (230, 425)]
                strokes.insert((contact - 0.9, strokes[1].1.merging(hop) { $1 }), at: 2)
                strokes.insert((contact - 0.8, strokes[1].1), at: 3)
            }
            keys += strokes
        }
        return keys.sorted { $0.0 < $1.0 }
    }

    func testFindsEveryStrokeAndSummarises() {
        let report = MatchAnalyzer.analyze(sequence(rally(split: true), until: 9.5), hand: .right)
        XCTAssertEqual(report.strokes.map(\.type), [.forehand, .backhand, .forehand])
        XCTAssertEqual(report.rallies, 1)
        XCTAssertEqual(report.summaries.map(\.type), [.forehand, .backhand])
        XCTAssertEqual(report.summaries.first?.count, 2)
        XCTAssertEqual(report.splitStepRate, 1)
        XCTAssertNotNil(report.movementMeters)
    }

    func testNoSplitStepIsCoached() {
        let report = MatchAnalyzer.analyze(sequence(rally(split: false), until: 9.5), hand: .right)
        XCTAssertEqual(report.splitStepRate, 0)
        let plan = Coach.ruleBased(report)
        XCTAssertTrue(plan.improvements.contains { $0.title == "Split step before every shot" })
        let prompt = Coach.matchPrompt(report, hand: .right)
        XCTAssertTrue(prompt.contains("Split step before 0% of groundstrokes"))
        XCTAssertTrue(prompt.contains("- Forehand: 2 hit"))
    }

    func testLongPausesSplitRallies() {
        let keys = groundstroke(contactAt: 1) + groundstroke(contactAt: 9)
        XCTAssertEqual(MatchAnalyzer.analyze(sequence(keys, until: 10.5), hand: .right).rallies, 2)
    }

    func testEmptyMatch() {
        let report = MatchAnalyzer.analyze(sequence([(0, [:]), (5, [:])], until: 5), hand: .right)
        XCTAssertTrue(report.strokes.isEmpty)
        XCTAssertTrue(Coach.ruleBased(report).summary.hasPrefix("No strokes were found"))
    }

    func testStrokeCoachingAndMatchParsing() throws {
        let stroke = try XCTUnwrap(StrokeAnalyzer.analyzeClip(sequence(groundstroke(backhand: true, twoHanded: true), until: 2), hand: .right))
        let prompt = Coach.prompt(stroke, hand: .right, hasImages: true)
        XCTAssertTrue(prompt.contains("The images show the two-handed backhand in order: preparation, contact, finish."))
        XCTAssertTrue(prompt.contains("Stroke: Two-handed backhand."))
        XCTAssertTrue(prompt.contains("[contact-in-front]"))

        let report = MatchAnalyzer.analyze(sequence(rally(split: false), until: 9.5), hand: .right)
        let reply = #"{"summary":"Good rally with solid groundstrokes.","measurement_review":[{"check_id":"knee-bend","trustworthy":true,"note":"x"}],"strengths":["Consistent"],"improvements":[{"title":"Split step","why":"Faster first step to the ball.","how":"Hop as they hit.","drill":"Say hop out loud."}],"next_session_focus":"Split step every ball."}"#
        let parsed = try XCTUnwrap(Coach.parse(reply, match: report, modelName: "Test"))
        XCTAssertTrue(parsed.measurementReview.isEmpty, "match reviews have no checks to review")
        XCTAssertEqual(parsed.strengths, Coach.ruleBased(report).strengths, "match strengths come from the data, not the model")
        XCTAssertTrue(Coach.matchPrompt(report, hand: .right).contains("Doing well:"))
        XCTAssertEqual(parsed.improvements.first?.title, "Split step")
    }

    func testTrackerReportsStrokeAfterFinish() {
        var tracker = StrokeTracker(hand: .right, type: nil)
        let results = sequence(groundstroke(), until: 2.5).compactMap { tracker.add($0) }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .forehand)
    }
}
