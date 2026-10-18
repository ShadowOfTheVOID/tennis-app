import Foundation

/// Where a coaching report came from.
public enum CoachSource: String, Codable, Sendable {
    /// Built-in rules, tips and drills (works on every phone, instantly).
    case rules
    /// An on-device language model.
    case onDeviceAI
}

/// Coaching feedback for one serve. Mirrors `CoachReport` in the Android `analysis` module.
public struct CoachReport: Codable, Sendable {
    public struct MeasurementReview: Codable, Sendable, Identifiable {
        public let checkId: String
        public let trustworthy: Bool
        public let note: String
        public var id: String { checkId }

        public init(checkId: String, trustworthy: Bool, note: String) {
            self.checkId = checkId
            self.trustworthy = trustworthy
            self.note = note
        }
    }

    public struct Improvement: Codable, Sendable, Identifiable {
        public let title: String
        public let why: String
        public let how: String
        public let drill: String
        public var id: String { title }

        public init(title: String, why: String, how: String, drill: String) {
            self.title = title
            self.why = why
            self.how = how
            self.drill = drill
        }
    }

    public let summary: String
    public let measurementReview: [MeasurementReview]
    public let strengths: [String]
    public let improvements: [Improvement]
    public let nextSessionFocus: String
    public var source: CoachSource = .rules
    /// Name of the model that wrote the report, when `source` is `.onDeviceAI`.
    public var modelName: String?

    public init(
        summary: String, measurementReview: [MeasurementReview], strengths: [String],
        improvements: [Improvement], nextSessionFocus: String, source: CoachSource = .rules, modelName: String? = nil
    ) {
        self.summary = summary
        self.measurementReview = measurementReview
        self.strengths = strengths
        self.improvements = improvements
        self.nextSessionFocus = nextSessionFocus
        self.source = source
        self.modelName = modelName
    }

    /// The IDs of checks the AI coach says not to trust.
    public var distrustedChecks: Set<String> {
        Set(measurementReview.filter { !$0.trustworthy }.map(\.checkId))
    }
}

/// Prompts, output schema, parsing and the rule-based coach shared by every coaching engine.
public enum Coach {
    // MARK: Rule-based coach

    /// Coaching built straight from the checks. Always available; also used as the
    /// skeleton the language models personalise.
    public static func ruleBased(_ result: ServeResult) -> CoachReport {
        let problems = result.checks.filter { $0.status == .bad } + result.checks.filter { $0.status == .warn }
        let improvements = problems.prefix(3).map {
            CoachReport.Improvement(title: $0.label, why: "Measured \($0.value). \(why[$0.id] ?? "")".trimmingCharacters(in: .whitespaces),
                                    how: $0.tip, drill: drill(for: $0.id))
        }
        let strengths = result.checks.filter { $0.status == .good }.map(\.label)
        let summary: String
        switch result.score {
        case .some(let s) where s >= 85: summary = "Strong serve posture (\(s)/100). Keep grooving it."
        case .some(let s) where s >= 60: summary = "Solid base (\(s)/100) with a couple of things to tidy up."
        case .some(let s): summary = "Score \(s)/100. Work on the fixes below one at a time."
        case .none: summary = "Not enough of your body was visible to score this serve. Film side-on with your whole body in frame."
        }
        return CoachReport(
            summary: summary,
            measurementReview: [],
            strengths: strengths,
            improvements: Array(improvements),
            nextSessionFocus: improvements.first.map { "\($0.title): \($0.how)" } ?? "Keep the same motion and build consistency.",
            source: .rules
        )
    }

    public static func drill(for checkId: String) -> String {
        drills[checkId] ?? "Shadow-serve slowly in front of a mirror, pausing on this position."
    }

    // MARK: Language-model prompts

    public static let instructions = """
    You are an experienced, encouraging tennis coach. A phone's pose tracker measured a recreational \
    player's serve at two moments, the trophy position and contact, and graded each check good, warn or bad.

    Each check lists the measured value, the target, the grade, how confident the tracker was, and the \
    analyzer's note. The analyzer's note tells you which way to fix it: trust it for direction.

    Pose tracking from one camera can be wrong. For every check, decide whether the measurement is \
    trustworthy: mark it untrustworthy only when its tracker confidence is low, the value is physically \
    implausible, or the photos clearly show something different. Use the check's id exactly as written in \
    the square brackets. Keep each note under 15 words.

    Then coach: list what the player already does well (checks graded good) and give at most three \
    improvements for checks graded bad or warn, the most important first. Each improvement has a short \
    title, why it matters, a short on-court cue, and one simple drill that is different from the cue. Base \
    advice only on trustworthy measurements. Use plain, friendly language and keep every field to one or \
    two sentences. Reply with JSON only.
    """

    /// The user turn: measurements, tracker confidence, and the rule-based plan to build on.
    public static func prompt(_ result: ServeResult, hand: Handedness, hasImages: Bool) -> String {
        var lines: [String] = []
        if hasImages {
            lines.append("The first image is the trophy position and the second is contact. Check the measurements against what you see.")
        }
        lines.append("Player is \(hand == .right ? "right" : "left")-handed.")
        for (eval, frame) in [(result.trophy, result.trophyFrame), (result.contact, result.contactFrame)] {
            guard let eval else { continue }
            lines.append("")
            lines.append("\(eval.phase.title), score \(eval.score.map(String.init) ?? "n/a")/100")
            for check in eval.checks {
                let confidence = frame.map { confidenceLabel($0.pose, checkId: check.id, hand: hand) } ?? "unknown"
                lines.append("- [\(check.id)] \(check.label): measured \(check.value), target \(targets[check.id] ?? "n/a"), "
                    + "graded \(check.status.rawValue), tracker confidence \(confidence). Analyzer note: \(check.tip)")
            }
        }
        if result.trophy == nil { lines.append("\nNo trophy position was found.") }
        if result.contact == nil { lines.append("\nNo contact point was found.") }

        let plan = ruleBased(result)
        if !plan.improvements.isEmpty {
            lines.append("\nSuggested drills you may use or improve on:")
            for item in plan.improvements { lines.append("- \(item.title): \(item.drill)") }
        }
        return lines.joined(separator: "\n")
    }

    /// JSON schema for constrained decoding; keys match `CoachReport`'s coding keys. The minimum lengths
    /// matter: without them the decoder is free to emit empty strings, and small models do.
    public static let schema: String = """
    {"type":"object","properties":{\
    "summary":{"type":"string","minLength":20},\
    "measurement_review":{"type":"array","items":{"type":"object","properties":{\
    "check_id":{"type":"string"},"trustworthy":{"type":"boolean"},"note":{"type":"string","minLength":5}},\
    "required":["check_id","trustworthy","note"]}},\
    "strengths":{"type":"array","items":{"type":"string","minLength":5}},\
    "improvements":{"type":"array","maxItems":3,"items":{"type":"object","properties":{\
    "title":{"type":"string","minLength":3},"why":{"type":"string","minLength":10},\
    "how":{"type":"string","minLength":10},"drill":{"type":"string","minLength":10}},\
    "required":["title","why","how","drill"]}},\
    "next_session_focus":{"type":"string","minLength":10}},\
    "required":["summary","measurement_review","strengths","improvements","next_session_focus"]}
    """

    /// Parse a model's JSON reply, tolerating surrounding text or code fences, and clean it up.
    /// Returns nil if it can't be used, so callers fall back to the rule-based coach.
    public static func parse(_ text: String, result: ServeResult, modelName: String) -> CoachReport? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let raw = try? JSONDecoder().decode(RawReport.self, from: Data(text[start...end].utf8))
        else { return nil }

        let known = Set(result.checks.map(\.id))
        let plan = ruleBased(result)
        // Fill any blank field from the analyzer's plan, which is in the same priority order.
        let improvements = raw.improvements.prefix(3).enumerated().compactMap { index, item -> CoachReport.Improvement? in
            let fallback = index < plan.improvements.count ? plan.improvements[index] : nil
            let title = item.title.trimmed.isEmpty ? (fallback?.title ?? "") : item.title.trimmed
            var how = item.how.trimmed
            if how.hasPrefix("Cue:") { how = String(how.dropFirst(4)).trimmed }
            if how.isEmpty { how = fallback?.how ?? "" }
            guard !title.isEmpty, !how.isEmpty else { return nil }
            return .init(
                title: title,
                why: item.why.trimmed.isEmpty ? (fallback?.why ?? "") : item.why.trimmed,
                how: how,
                drill: item.drill.trimmed.isEmpty ? (fallback?.drill ?? drill(for: "")) : item.drill.trimmed
            )
        }
        let summary = raw.summary.trimmed
        guard !summary.isEmpty || !improvements.isEmpty else { return nil }
        // A summary holding JSON or an essay means the model lost the format; don't show it.
        guard !summary.contains("{"), summary.count <= 800 else { return nil }

        return CoachReport(
            summary: summary.isEmpty ? plan.summary : summary,
            // Drop reviews of checks that don't exist (small models sometimes invent them).
            measurementReview: raw.measurementReview
                .map { .init(checkId: normalizeId($0.checkId), trustworthy: $0.trustworthy, note: $0.note) }
                .filter { known.contains($0.checkId) },
            strengths: raw.strengths.filter { !$0.isBlank }.prefix(5).map { $0 },
            improvements: Array(improvements),
            nextSessionFocus: raw.nextSessionFocus.isBlank
                ? (improvements.first?.title ?? plan.nextSessionFocus) : raw.nextSessionFocus.trimmed,
            source: .onDeviceAI,
            modelName: modelName
        )
    }

    private struct RawReport: Decodable {
        let summary: String
        let measurementReview: [CoachReport.MeasurementReview]
        let strengths: [String]
        let improvements: [CoachReport.Improvement]
        let nextSessionFocus: String

        enum CodingKeys: String, CodingKey {
            case summary, strengths, improvements
            case measurementReview = "measurement_review"
            case nextSessionFocus = "next_session_focus"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
            measurementReview = (try? c.decode([RawReview].self, forKey: .measurementReview))?.map(\.review) ?? []
            strengths = (try? c.decode([String].self, forKey: .strengths)) ?? []
            improvements = (try? c.decode([RawImprovement].self, forKey: .improvements))?.map(\.improvement) ?? []
            nextSessionFocus = (try? c.decode(String.self, forKey: .nextSessionFocus)) ?? ""
        }
    }

    private struct RawImprovement: Decodable {
        let improvement: CoachReport.Improvement

        enum CodingKeys: String, CodingKey { case title, why, how, drill }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func field(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
            improvement = .init(title: field(.title), why: field(.why), how: field(.how), drill: field(.drill))
        }
    }

    private struct RawReview: Decodable {
        let review: CoachReport.MeasurementReview

        enum CodingKeys: String, CodingKey { case checkId = "check_id", trustworthy, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            review = .init(
                checkId: try c.decode(String.self, forKey: .checkId),
                trustworthy: (try? c.decode(Bool.self, forKey: .trustworthy)) ?? true,
                note: (try? c.decode(String.self, forKey: .note)) ?? ""
            )
        }
    }

    /// Models sometimes echo ids as "id knee-bend" or "[knee-bend]".
    static func normalizeId(_ raw: String) -> String {
        var id = raw.trimmed
        if id.hasPrefix("id ") { id = String(id.dropFirst(3)) }
        return id.trimmingCharacters(in: CharacterSet(charactersIn: "[]`\" ").union(.whitespaces)).lowercased()
    }

    /// How confident the tracker was in the joints a check uses: high, medium or low.
    public static func confidenceLabel(_ pose: Pose, checkId: String, hand: Handedness) -> String {
        let right = hand == .right
        let hit: (shoulder: Joint, elbow: Joint, wrist: Joint) = right
            ? (.rightShoulder, .rightElbow, .rightWrist) : (.leftShoulder, .leftElbow, .leftWrist)
        let toss: (shoulder: Joint, elbow: Joint, wrist: Joint) = right
            ? (.leftShoulder, .leftElbow, .leftWrist) : (.rightShoulder, .rightElbow, .rightWrist)
        let joints: [Joint]
        switch checkId {
        case "toss-arm-straight", "toss-arm-tuck": joints = [toss.shoulder, toss.elbow, toss.wrist]
        case "toss-arm-high": joints = [toss.wrist, .nose]
        case "hit-elbow-bend", "hit-arm-extended": joints = [hit.shoulder, hit.elbow, hit.wrist]
        case "hit-elbow-height": joints = [hit.shoulder, hit.elbow]
        case "contact-height": joints = [hit.wrist, .nose]
        case "shoulder-tilt": joints = [.leftShoulder, .rightShoulder]
        case "torso-upright": joints = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        case "knee-bend", "leg-drive": joints = [.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        default: return "unknown"
        }
        let lowest = joints.map { pose.joints[$0]?.confidence ?? 0 }.min() ?? 0
        return lowest >= 0.7 ? "high" : lowest >= 0.5 ? "medium" : "low"
    }

    // MARK: Coaching content (keep in sync with Coach.kt)

    private static let targets: [String: String] = [
        "toss-arm-straight": "155–180°",
        "toss-arm-high": "at least 0.60× torso above the nose",
        "hit-elbow-bend": "70–115°",
        "hit-elbow-height": "at or above shoulder height",
        "shoulder-tilt": "at least 0.12× torso",
        "knee-bend": "110–155°",
        "hit-arm-extended": "160–180°",
        "contact-height": "at least 0.90× torso above the nose",
        "leg-drive": "160–180°",
        "torso-upright": "20° or less",
        "toss-arm-tuck": "tucked",
    ]

    private static let why: [String: String] = [
        "toss-arm-straight": "A straight tossing arm gives a consistent, repeatable toss.",
        "toss-arm-high": "A high release keeps the ball on line and lifts your front side.",
        "hit-elbow-bend": "The 'L' stores energy for the racket drop and a fast swing up.",
        "hit-elbow-height": "A low elbow costs racket speed and puts stress on the shoulder.",
        "shoulder-tilt": "The tilt lets you swing up to the ball instead of across it.",
        "knee-bend": "Loaded legs are where most of the serve's power starts.",
        "hit-arm-extended": "Full extension means a higher contact point and more margin over the net.",
        "contact-height": "Higher contact opens up the service box.",
        "leg-drive": "Driving up transfers your leg power into the racket.",
        "torso-upright": "Leaning sideways usually means the toss drifted and costs balance.",
        "toss-arm-tuck": "Tucking the tossing arm speeds up your shoulder rotation.",
    ]

    private static let drills: [String: String] = [
        "toss-arm-straight": "Toss 10 balls without hitting, keeping the arm straight, so each ball lands on a racket laid in front of you.",
        "toss-arm-high": "Toss and freeze with your tossing hand pointing at the ball for 2 seconds before letting it drop.",
        "hit-elbow-bend": "From the trophy position, hold the racket behind you with the elbow at 90° for 3 seconds, 10 reps.",
        "hit-elbow-height": "Shadow-serve in front of a mirror and check your hitting elbow reaches shoulder height before you swing.",
        "shoulder-tilt": "Point your tossing hand at the ball and feel the front shoulder rise as the back shoulder drops; hold 3 seconds.",
        "knee-bend": "Do 10 slow trophy-position squats, then jump up through an imaginary ball.",
        "hit-arm-extended": "Serve at a high target (top of the fence or a partner's raised hand) and reach to touch it at full stretch.",
        "contact-height": "Toss slightly higher and practise hitting at the very peak of your reach, 10 balls.",
        "leg-drive": "Serve focusing only on pushing up off the ground so you land inside the court.",
        "torso-upright": "Toss so the ball would land a foot inside the baseline, and stay tall through contact.",
        "toss-arm-tuck": "Shadow-serve pulling the tossing hand into your stomach as the racket goes up.",
    ]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}
