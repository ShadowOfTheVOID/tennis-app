import Foundation
import ServeAnalysis
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Coaching feedback for one serve.
struct CoachReport {
    struct MeasurementReview: Identifiable {
        let checkId: String
        let trustworthy: Bool
        let note: String
        var id: String { checkId }
    }

    struct Improvement: Identifiable {
        let title: String
        let why: String
        let how: String
        let drill: String
        var id: String { title }
    }

    let summary: String
    let measurementReview: [MeasurementReview]
    let strengths: [String]
    let improvements: [Improvement]
    let nextSessionFocus: String
    /// True when written by the on-device language model, false for the built-in rule-based coach.
    let fromAI: Bool
}

/// Turns a serve's measurements into coaching. Uses Apple's on-device language model
/// (Foundation Models, iOS 26+ with Apple Intelligence) — no API key, no network, nothing
/// leaves the phone. Falls back to rule-based coaching where that model isn't available.
enum AICoach {
    /// Why the on-device model can't be used, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use the AI coach."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again later."
            case .unavailable: return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "The AI coach needs iOS 26 with Apple Intelligence."
    }

    static func review(_ serve: ReviewedServe, hand: Handedness) async throws -> CoachReport {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), unavailableReason == nil {
            return try await OnDeviceCoach.review(serve, hand: hand)
        }
        #endif
        return ruleBased(serve.result)
    }

    // MARK: Prompt input

    /// The measurements plus how confident the pose tracker was in each key frame,
    /// so the model can judge which numbers to trust.
    static func measurementsText(_ serve: ReviewedServe, hand: Handedness) -> String {
        var lines = ["Player is \(hand == .right ? "right" : "left")-handed."]
        let frames: [(Evaluation?, PoseSample?)] = [(serve.result.trophy, serve.trophySample), (serve.result.contact, serve.contactSample)]
        for (eval, sample) in frames {
            guard let eval else { continue }
            lines.append("")
            lines.append("\(eval.phase.title) — score \(eval.score.map(String.init) ?? "n/a")/100")
            if let sample {
                let low = Joint.allCases
                    .filter { (sample.pose.joints[$0]?.confidence ?? 0) < 0.5 }
                    .map(\.rawValue)
                lines.append("Pose tracker confidence: low on \(low.isEmpty ? "no joints" : low.joined(separator: ", ")).")
            }
            for check in eval.checks {
                lines.append("- [\(check.id)] \(check.label): \(check.value) → \(check.status.rawValue)")
            }
        }
        if serve.result.trophy == nil { lines.append("\nNo trophy position was found.") }
        if serve.result.contact == nil { lines.append("\nNo contact point was found.") }
        return lines.joined(separator: "\n")
    }

    static let instructions = """
    You are an experienced, encouraging tennis coach. A phone's pose tracker measured a recreational \
    player's serve at two moments, the trophy position and contact, and graded each check good, warn or bad.

    Pose tracking from one camera can be wrong, especially on joints it reports low confidence for or \
    when values look physically implausible. For each check, say whether the measurement is trustworthy.

    Then coach: name what the player already does well and give at most three improvements, the most \
    important first, each with why it matters, a short on-court cue and one simple drill. Base the \
    advice only on trustworthy measurements. Use plain, friendly language.
    """

    // MARK: Fallback

    /// Coaching built straight from the checks, for devices without Apple Intelligence.
    static func ruleBased(_ result: ServeResult) -> CoachReport {
        let checks = (result.trophy?.checks ?? []) + (result.contact?.checks ?? [])
        let problems = checks.filter { $0.status == .bad } + checks.filter { $0.status == .warn }
        let improvements = problems.prefix(3).map {
            CoachReport.Improvement(title: $0.label, why: "Measured \($0.value).", how: $0.tip, drill: drills[$0.id] ?? "Shadow-serve slowly in front of a mirror, pausing on this position.")
        }
        let strengths = checks.filter { $0.status == .good }.map(\.label)
        let summary = result.score.map { "On-device score: \($0)/100." } ?? "Not enough of your body was visible to score this serve."
        return CoachReport(
            summary: summary,
            measurementReview: [],
            strengths: strengths,
            improvements: Array(improvements),
            nextSessionFocus: improvements.first?.title ?? "Keep grooving the same motion.",
            fromAI: false
        )
    }

    private static let drills: [String: String] = [
        "toss-arm-straight": "Toss 10 balls without hitting, keeping the arm straight and letting the ball land on a racket on the ground in front of you.",
        "toss-arm-high": "Toss and freeze with your tossing hand pointing at the ball for 2 seconds before letting it drop.",
        "hit-elbow-bend": "From the trophy position, hold the racket behind you with the elbow at 90° for 3 seconds, 10 reps.",
        "hit-elbow-height": "Shadow-serve with a towel under your hitting armpit falling away as the elbow lifts to shoulder height.",
        "shoulder-tilt": "Point your tossing hand at the ball and feel your front shoulder rise while the back shoulder drops — hold for 3 seconds.",
        "knee-bend": "Do 10 slow trophy-position squats, then jump up through an imaginary ball.",
        "hit-arm-extended": "Serve at a target held high (fence top or a coach's hand) and reach to touch it at full stretch.",
        "contact-height": "Practise tossing slightly higher and hitting at the very peak of your reach.",
        "leg-drive": "Serve from your knees bent, focusing on pushing up off the ground so you land inside the court.",
        "torso-upright": "Toss so the ball would land a foot inside the baseline and stay tall through contact.",
        "toss-arm-tuck": "Shadow-serve pulling the tossing hand into your stomach as the racket goes up.",
    ]
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum OnDeviceCoach {
    @Generable
    struct Report {
        @Guide(description: "Two or three sentences summarising the serve posture.")
        var summary: String
        @Guide(description: "One entry per measured check, using the id in square brackets.")
        var measurementReview: [Review]
        @Guide(description: "Things the player already does well.")
        var strengths: [String]
        @Guide(description: "At most three improvements, most important first.")
        var improvements: [Improvement]
        @Guide(description: "One sentence on what to focus on next practice.")
        var nextSessionFocus: String
    }

    @Generable
    struct Review {
        @Guide(description: "The check id from the square brackets, e.g. knee-bend.")
        var checkId: String
        @Guide(description: "Whether this measurement looks reliable.")
        var trustworthy: Bool
        @Guide(description: "A short reason.")
        var note: String
    }

    @Generable
    struct Improvement {
        var title: String
        @Guide(description: "Why this matters for the serve.")
        var why: String
        @Guide(description: "A short on-court cue for fixing it.")
        var how: String
        @Guide(description: "One simple drill to practise it.")
        var drill: String
    }

    static func review(_ serve: ReviewedServe, hand: Handedness) async throws -> CoachReport {
        let session = LanguageModelSession(instructions: AICoach.instructions)
        let prompt = "Here are the measurements of my serve. How can I improve?\n\n" + AICoach.measurementsText(serve, hand: hand)
        let report = try await session.respond(to: prompt, generating: Report.self).content
        return CoachReport(
            summary: report.summary,
            measurementReview: report.measurementReview.map { .init(checkId: $0.checkId, trustworthy: $0.trustworthy, note: $0.note) },
            strengths: report.strengths,
            improvements: report.improvements.prefix(3).map { .init(title: $0.title, why: $0.why, how: $0.how, drill: $0.drill) },
            nextSessionFocus: report.nextSessionFocus,
            fromAI: true
        )
    }
}
#endif
