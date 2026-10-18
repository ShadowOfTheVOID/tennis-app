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
/// Mirrors `Coach` in the Android `analysis` module: keep the text identical.
public enum Coach {
    // MARK: Rule-based coach

    /// Coaching built straight from the checks. Always available; also used as the
    /// skeleton the language models personalise.
    public static func ruleBased(_ result: StrokeResult, hand: Handedness) -> CoachReport {
        let problems = result.checks.filter { $0.status == .bad } + result.checks.filter { $0.status == .warn }
        let improvements = problems.prefix(3).map {
            CoachReport.Improvement(title: $0.label, why: "Measured \($0.value). \(why[$0.id] ?? "")".trimmingCharacters(in: .whitespaces),
                                    how: $0.tip, drill: drill(for: $0.id))
        }
        let strengths = result.checks.filter { $0.status == .good }.map(\.label)
        let name = result.title.lowercased()
        let summary: String
        switch result.score {
        case .some(let s) where s >= 85: summary = "Strong \(name) (\(s)/100). Keep grooving it."
        case .some(let s) where s >= 60: summary = "Solid \(name) (\(s)/100) with a couple of things to tidy up."
        case .some(let s): summary = "\(result.title) score \(s)/100. Work on the fixes below one at a time."
        case .none: summary = "Not enough of your body was visible to score this \(name). Film side-on with your whole body in frame."
        }
        return CoachReport(
            summary: summary,
            measurementReview: lowConfidenceReviews(result, hand: hand),
            strengths: strengths,
            improvements: Array(improvements),
            nextSessionFocus: improvements.first.map { "\($0.title): \($0.how)" } ?? "Keep the same motion and build consistency.",
            source: .rules
        )
    }

    public static func ruleBased(_ result: ServeResult, hand: Handedness) -> CoachReport { ruleBased(result.stroke, hand: hand) }

    /// Checks measured from joints the tracker could barely see. Always flagged, whatever a model says.
    static func lowConfidenceReviews(_ result: StrokeResult, hand: Handedness) -> [CoachReport.MeasurementReview] {
        result.evaluations.flatMap { eval -> [CoachReport.MeasurementReview] in
            guard let frame = result.frame(for: eval.phase) else { return [] }
            return eval.checks
                .filter { $0.status != .unknown && confidenceLabel(frame.pose, checkId: $0.id, hand: hand) == "low" }
                .map { .init(checkId: $0.id, trustworthy: false, note: "The tracker couldn't see these joints clearly, so this may be off.") }
        }
    }

    public static func drill(for checkId: String) -> String {
        drills[checkId] ?? "Shadow-swing slowly in front of a mirror, pausing on this position."
    }

    // MARK: Language-model prompts

    public static let instructions = """
    You are an experienced, encouraging tennis coach. A phone's pose tracker measured a recreational \
    player's tennis stroke at its key moments and graded each check good, warn or bad.

    Each check lists the measured value, the target, the grade, how confident the tracker was, and the \
    analyzer's note. The analyzer's note tells you which way to fix it: trust it for direction.

    Pose tracking from one camera can be wrong. In measurement_review, list only the checks whose \
    measurement is untrustworthy: its tracker confidence is low, the value is physically implausible, or \
    the photos clearly show something different. Use the check's id exactly as written in the square \
    brackets and keep each note under 15 words. An empty list is fine.

    Then coach: list what the player already does well (checks graded good) and give at most three \
    improvements for checks graded bad or warn, the most important first. Each improvement has a short \
    title, why it matters, a short on-court cue, and one simple drill that is different from the cue. Base \
    advice only on trustworthy measurements. Use plain, friendly language and keep every field to one or \
    two sentences. Reply with JSON only.
    """

    /// The user turn: measurements, tracker confidence, and the rule-based plan to build on.
    public static func prompt(_ result: StrokeResult, hand: Handedness, hasImages: Bool) -> String {
        var lines: [String] = []
        if hasImages {
            let order = result.keyFrames.map { $0.phase.title.lowercased() }.joined(separator: ", ")
            lines.append("The images show the \(result.title.lowercased()) in order: \(order). Check the measurements against what you see.")
        }
        lines.append("Stroke: \(result.title). Player is \(hand == .right ? "right" : "left")-handed.")
        for phase in result.type.phases {
            guard let eval = result.evaluation(for: phase) else {
                lines.append("")
                lines.append("No \(phase.title.lowercased()) was found.")
                continue
            }
            let frame = result.frame(for: phase)
            lines.append("")
            lines.append("\(phase.title), score \(eval.score.map(String.init) ?? "n/a")/100")
            for check in eval.checks {
                let confidence = frame.map { confidenceLabel($0.pose, checkId: check.id, hand: hand) } ?? "unknown"
                lines.append("- [\(check.id)] \(check.label): measured \(check.value), target \(targets[check.id] ?? "n/a"), "
                    + "graded \(check.status.rawValue), tracker confidence \(confidence). Analyzer note: \(check.tip)")
            }
        }

        let plan = ruleBased(result, hand: hand)
        if !plan.improvements.isEmpty {
            lines.append("")
            lines.append("Suggested drills you may use or improve on:")
            for item in plan.improvements { lines.append("- \(item.title): \(item.drill)") }
        }
        return lines.joined(separator: "\n")
    }

    public static func prompt(_ result: ServeResult, hand: Handedness, hasImages: Bool) -> String {
        prompt(result.stroke, hand: hand, hasImages: hasImages)
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

    /// Parse a model's JSON reply about one stroke. Nil if it can't be used, so callers fall back to the rules.
    public static func parse(_ text: String, result: StrokeResult, hand: Handedness, modelName: String) -> CoachReport? {
        let plan = ruleBased(result, hand: hand)
        return parse(text, known: Set(result.checks.map(\.id)), plan: plan, forcedReviews: plan.measurementReview, modelName: modelName)
    }

    public static func parse(_ text: String, result: ServeResult, hand: Handedness, modelName: String) -> CoachReport? {
        parse(text, result: result.stroke, hand: hand, modelName: modelName)
    }

    // MARK: Match coaching

    public static let matchInstructions = """
    You are an experienced, encouraging tennis coach reviewing a recreational player's match video. A phone \
    tracked the player's body and summarised each kind of stroke (how many, the average score out of 100 and \
    the goal most often missed, with its fix), plus footwork estimates. Stroke types are detected automatically from body \
    position and can occasionally be wrong, and footwork numbers are estimates.

    Write a short summary of the match, list what the player does well, and give at most three improvements, \
    the most important first. Each improvement has a short title, why it matters, a short on-court cue, and \
    one simple drill that is different from the cue. Only list strengths from the "Doing well" list, base \
    the improvements on the suggested priorities in that order, and never invent numbers or habits that \
    aren't in the data. Leave measurement_review empty. Use plain, friendly language, keep every field to \
    one or two sentences, and reply with JSON only.
    """

    /// Coaching for a whole match, built from the stroke summaries and footwork.
    public static func ruleBased(_ match: MatchReport) -> CoachReport {
        let ranked = match.summaries.filter { $0.averageScore != nil }.sorted { ($0.averageScore ?? 0) < ($1.averageScore ?? 0) }
        var improvements: [CoachReport.Improvement] = []
        func strokeFix(_ s: StrokeSummary) {
            guard let fix = s.commonFix, let avg = s.averageScore, avg < 85 else { return }
            improvements.append(.init(
                title: "\(s.type.title): \(fix.label.lowercased())",
                why: "Your \(s.type.title.lowercased())s averaged \(avg)/100 and this was the most common problem. \(why[fix.id] ?? "")"
                    .trimmingCharacters(in: .whitespaces),
                how: fix.tip,
                drill: drill(for: fix.id)
            ))
        }
        if let weakest = ranked.first { strokeFix(weakest) }
        if let rate = match.splitStepRate, rate < 0.5 {
            improvements.append(.init(
                title: "Split step before every shot",
                why: "A small hop as your opponent hits lets you push off quickly in either direction. \(why["split-step"]!)",
                how: "Hop lightly onto the balls of your feet just as your opponent swings.",
                drill: drill(for: "split-step")
            ))
        }
        if let rate = match.readyStanceRate, rate < 0.5 {
            improvements.append(.init(
                title: "Stay low between shots",
                why: "With straight legs you lose the first step to the ball. \(why["ready-knees"]!)",
                how: "Keep your knees bent and the racket up in front of you while you wait.",
                drill: drill(for: "ready-knees")
            ))
        }
        for s in ranked.dropFirst() where improvements.count < 3 { strokeFix(s) }

        var strengths = match.summaries.compactMap { s -> String? in
            guard let avg = s.averageScore, avg >= 75 else { return nil }
            return "Solid \(s.type.title.lowercased())s (average \(avg)/100)"
        }
        if let rate = match.splitStepRate, rate >= 0.7 { strengths.append("Good split-step habit") }
        if let rate = match.readyStanceRate, rate >= 0.7 { strengths.append("Athletic ready stance between shots") }

        var summary = match.countsText
        if let score = match.score { summary += ", average score \(score)/100" }
        summary += "."
        if let best = ranked.last, let worst = ranked.first, best.type != worst.type {
            summary += " Your best stroke was the \(best.type.title.lowercased()); the biggest gain is in your \(worst.type.title.lowercased())."
        }
        if match.strokes.isEmpty {
            summary = "No strokes were found. Film from the side with your whole body in frame, and keep the camera still."
        }
        let plan = Array(improvements.prefix(3))
        return CoachReport(
            summary: summary,
            measurementReview: [],
            strengths: strengths,
            improvements: plan,
            nextSessionFocus: plan.first.map { "\($0.title): \($0.how)" } ?? "Keep playing the same way and build consistency.",
            source: .rules
        )
    }

    /// The user turn for match coaching.
    public static func matchPrompt(_ match: MatchReport, hand: Handedness) -> String {
        let minutes = Int(match.duration) / 60
        let seconds = Int(match.duration) % 60
        var lines = [
            "Player is \(hand == .right ? "right" : "left")-handed. Video length \(minutes) min \(seconds) s. \(match.countsText).",
            "",
            "Strokes:",
        ]
        for s in match.summaries {
            var line = "- \(s.type.title): \(s.count) hit, average score \(s.averageScore.map { "\($0)/100" } ?? "n/a")"
            // Name the check as a goal not met, then the fix, so the model can't read the goal as the problem.
            if let fix = s.commonFix { line += ". Most often missed: \"\(fix.label)\" (graded \(fix.status.rawValue)). The fix: \(fix.tip)" }
            lines.append(line)
        }
        if match.summaries.isEmpty { lines.append("- none found") }
        lines.append("")
        lines.append("Footwork:")
        if let rate = match.splitStepRate {
            lines.append("- Split step before \(Int((rate * 100).rounded()))% of groundstrokes and volleys (target: every shot).")
        }
        if let rate = match.readyStanceRate {
            lines.append("- Knees-bent ready stance \(Int((rate * 100).rounded()))% of the time between shots (target: most of the time).")
        }
        if let m = match.movementMeters, m >= 1 { lines.append("- About \(Int(m.rounded())) m of side-to-side movement.") }

        let plan = ruleBased(match)
        lines.append("")
        lines.append("Doing well:")
        lines += plan.strengths.isEmpty ? ["- nothing stands out yet"] : plan.strengths.map { "- \($0)" }
        if !plan.improvements.isEmpty {
            lines.append("")
            lines.append("Suggested priorities you may use or improve on:")
            for item in plan.improvements { lines.append("- \(item.title): \(item.drill)") }
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ text: String, match: MatchReport, modelName: String) -> CoachReport? {
        let plan = ruleBased(match)
        // Strengths come from the measured data only, so the model can't praise habits it didn't see.
        return parse(text, known: [], plan: plan, fixedStrengths: plan.strengths, modelName: modelName)
    }

    // MARK: Parsing

    /// Parse a model's JSON reply, tolerating surrounding text or code fences, and clean it up.
    /// `known` lists the check ids it may review; `plan` fills in anything left blank; `forcedReviews`
    /// override the model's own reviews; `fixedStrengths` replace the model's strengths.
    static func parse(
        _ text: String, known: Set<String>, plan: CoachReport, forcedReviews: [CoachReport.MeasurementReview] = [],
        fixedStrengths: [String]? = nil, modelName: String
    ) -> CoachReport? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let raw = try? JSONDecoder().decode(RawReport.self, from: Data(text[start...end].utf8))
        else { return nil }

        // Fill any blank field from the analyzer's plan, which is in the same priority order.
        let improvements = raw.improvements.prefix(3).enumerated().compactMap { index, item -> CoachReport.Improvement? in
            let fallback = index < plan.improvements.count ? plan.improvements[index] : nil
            let title = item.title.trimmed.isEmpty ? (fallback?.title ?? "") : item.title.trimmed
            var how = item.how.trimmed
            if how.hasPrefix("Cue:") { how = String(how.dropFirst(4)).trimmed }
            // Models sometimes repeat the drill inside the cue.
            if let drillStart = how.range(of: "Drill:") { how = String(how[..<drillStart.lowerBound]).trimmed }
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
            measurementReview: mergeReviews(
                raw.measurementReview
                    .map { .init(checkId: normalizeId($0.checkId), trustworthy: $0.trustworthy, note: $0.note) }
                    .filter { known.contains($0.checkId) },
                forced: forcedReviews
            ),
            strengths: fixedStrengths ?? raw.strengths.filter { !$0.isBlank }.prefix(5).map { $0 },
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

    /// The model's reviews in order, one per check, with `forced` ones replacing or added to them.
    static func mergeReviews(_ reviews: [CoachReport.MeasurementReview], forced: [CoachReport.MeasurementReview]) -> [CoachReport.MeasurementReview] {
        var seen = Set<String>()
        var merged: [CoachReport.MeasurementReview] = []
        for review in reviews where seen.insert(review.checkId).inserted {
            merged.append(forced.first { $0.checkId == review.checkId } ?? review)
        }
        return merged + forced.filter { !seen.contains($0.checkId) }
    }

    /// Models sometimes echo ids as "id knee-bend", "[knee-bend]" or "knee_bend".
    static func normalizeId(_ raw: String) -> String {
        var id = raw.trimmed
        if id.hasPrefix("id ") { id = String(id.dropFirst(3)) }
        return id.trimmingCharacters(in: CharacterSet(charactersIn: "[]`\" ").union(.whitespaces)).lowercased()
            .replacingOccurrences(of: "_", with: "-")
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
        case "knee-bend", "leg-drive", "prep-knees", "ready-knees":
            joints = [.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        case "contact-spacing", "volley-firm": joints = [hit.shoulder, hit.elbow, hit.wrist]
        case "prep-takeback", "volley-compact", "finish-high": joints = [hit.wrist, .leftShoulder, .rightShoulder]
        case "contact-in-front", "strike-zone", "volley-hands-up": joints = [hit.wrist, .leftHip, .rightHip]
        case "finish-through", "volley-short": joints = [hit.wrist]
        case "prep-stance", "ready-stance": joints = [.leftAnkle, .rightAnkle]
        case "prep-off-arm": joints = [toss.wrist, .leftShoulder, .rightShoulder]
        case "oh-off-arm-up": joints = [toss.wrist, .nose]
        case "oh-racket-up": joints = [hit.shoulder, hit.elbow]
        case "oh-contact-high": joints = [hit.wrist, .nose]
        case "contact-balance", "finish-balance": joints = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        case "ready-hands": joints = [.leftWrist, .rightWrist, .leftHip, .rightHip]
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
        "prep-takeback": "at least 0.50× torso behind the shoulders",
        "prep-knees": "110–160°",
        "prep-stance": "at least 0.90× torso between the ankles",
        "prep-off-arm": "at least 0.15× torso in front of the shoulders",
        "contact-in-front": "at least 0.20× torso in front of the hips (0.30× on volleys)",
        "contact-spacing": "110–180° (150–180° on a one-handed backhand)",
        "strike-zone": "between 0.30× torso below and 0.90× torso above the hips",
        "contact-balance": "20° or less",
        "finish-high": "at or above shoulder height",
        "finish-through": "at least 2.0× torso of hand travel",
        "finish-balance": "20° or less",
        "volley-compact": "0.40× torso or less behind the shoulders",
        "volley-hands-up": "at least 0.30× torso above the hips",
        "volley-firm": "100–170°",
        "volley-short": "1.2× torso or less of hand travel",
        "oh-off-arm-up": "at least 0.30× torso above the nose",
        "oh-racket-up": "at or above shoulder height",
        "oh-contact-high": "at least 0.70× torso above the nose",
        "ready-knees": "120–165°",
        "ready-stance": "at least 0.90× torso between the ankles",
        "ready-hands": "both hands above the waist",
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
        "prep-takeback": "An early turn gives you time and lets you swing smoothly instead of rushing.",
        "prep-knees": "Bent knees let you push up into the ball for free power and better balance.",
        "prep-stance": "A wide base keeps you stable while you rotate.",
        "prep-off-arm": "The non-hitting arm drives the shoulder turn and helps you judge the ball.",
        "contact-in-front": "Hitting in front lets your body weight go into the shot and gives you control.",
        "contact-spacing": "The right spacing lets you swing freely instead of getting jammed.",
        "strike-zone": "Between waist and chest is where you can swing hardest with control.",
        "contact-balance": "Balance at contact keeps your shots consistent.",
        "finish-high": "A high finish means you swung up through the ball, which adds topspin and net clearance.",
        "finish-through": "Swinging through the ball keeps the racket face stable and adds depth.",
        "finish-balance": "Finishing balanced means you're ready for the next shot sooner.",
        "volley-compact": "There's no time for a big swing at the net; a short backswing keeps you on time.",
        "volley-hands-up": "Starting with the racket up saves time and keeps the volley firm.",
        "volley-firm": "A firm arm lets you use the ball's pace instead of swinging.",
        "volley-short": "A short punch keeps the volley controlled and in the court.",
        "oh-off-arm-up": "Pointing at the ball lines up the overhead and keeps your head up.",
        "oh-racket-up": "Getting the racket up early gives you time to hit at the top of your reach.",
        "oh-contact-high": "Hitting at full reach gives you the best angle down into the court.",
        "ready-knees": "Bent knees let you take your first step to the ball faster.",
        "ready-stance": "A wide stance lets you push off in either direction.",
        "ready-hands": "A racket held up in front is ready for both forehands and backhands.",
        "split-step": "It's the single biggest footwork habit that separates good players.",
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
        "prep-takeback": "Have a partner feed balls and call 'turn' as the ball crosses the net; be fully turned before it bounces.",
        "prep-knees": "Shadow-swing 10 times, sitting slightly into your legs on the turn and pushing up into the swing.",
        "prep-stance": "Rally with a racket-length gap marked between your feet with two balls, keeping that width for every shot.",
        "prep-off-arm": "Shadow forehands catching an imaginary ball with your non-hitting hand as you turn.",
        "contact-in-front": "Drop-feed balls to yourself and hit them a step in front of your front foot, 15 balls.",
        "contact-spacing": "Place a ball an arm's length from your hip and shadow-swing to it; then hit drop feeds at that spacing.",
        "strike-zone": "Rally aiming to let every ball drop to waist height before you hit; move back or bend to make it happen.",
        "contact-balance": "Hit 10 forehands and freeze at contact, checking your head is over your hips.",
        "finish-high": "Swing and catch the racket throat with your non-hitting hand over your opposite shoulder, 10 reps.",
        "finish-through": "Shadow-swing slowly, letting the racket finish all the way around your body, then speed up.",
        "finish-balance": "Hit 10 balls and hold each finish for two seconds before relaxing.",
        "volley-compact": "Stand with your back near a fence and volley partner feeds; the fence stops a big backswing.",
        "volley-hands-up": "Volley partner feeds while keeping the racket head above your hands the whole time.",
        "volley-firm": "Catch-and-push drill: let the ball meet your strings and push it forward without swinging, 20 balls.",
        "volley-short": "Volley feeds and stop the racket as soon as you make contact, like catching the ball.",
        "oh-off-arm-up": "Have a partner lob 10 balls; point at each one with your non-hitting hand until you swing.",
        "oh-racket-up": "From a sideways stance, practise lifting the racket straight into the trophy position as the lob goes up.",
        "oh-contact-high": "Practise quick side-steps back under lobs so you can hit each one at full reach.",
        "ready-knees": "Between every shot in a rally, bounce lightly with your knees bent until the ball is struck.",
        "ready-stance": "Shadow-play: return to a wide, balanced stance with racket up after every swing.",
        "ready-hands": "Rally holding the racket throat with your non-hitting hand between every shot.",
        "split-step": "Rally and say 'hop' out loud each time your partner hits; land on the balls of your feet as they make contact.",
    ]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}
