package com.servecoach.analysis

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Where a coaching report came from. */
@Serializable
enum class CoachSource {
    /** Built-in rules, tips and drills (works on every phone, instantly). */
    RULES,
    /** An on-device language model. */
    ON_DEVICE_AI,
}

/** Coaching feedback for one serve. Mirrors `CoachReport` in the Swift package. */
@Serializable
data class CoachReport(
    val summary: String,
    val measurementReview: List<MeasurementReview>,
    val strengths: List<String>,
    val improvements: List<Improvement>,
    val nextSessionFocus: String,
    val source: CoachSource = CoachSource.RULES,
    /** Name of the model that wrote the report, when [source] is [CoachSource.ON_DEVICE_AI]. */
    val modelName: String? = null,
) {
    @Serializable
    data class MeasurementReview(
        @SerialName("check_id") val checkId: String,
        val trustworthy: Boolean,
        val note: String,
    )

    @Serializable
    data class Improvement(val title: String, val why: String, val how: String, val drill: String)

    /** The IDs of checks the AI coach says not to trust. */
    val distrustedChecks: Set<String> get() = measurementReview.filter { !it.trustworthy }.map { it.checkId }.toSet()
}

/** Prompts, output schema, parsing and the rule-based coach shared by every coaching engine. */
object Coach {
    // Rule-based coach

    /**
     * Coaching built straight from the checks. Always available; also used as the skeleton
     * the language models personalise.
     */
    fun ruleBased(result: StrokeResult, hand: Handedness): CoachReport {
        val problems = result.checks.filter { it.status == Status.BAD } + result.checks.filter { it.status == Status.WARN }
        val improvements = problems.take(3).map {
            CoachReport.Improvement(
                title = it.label,
                why = "Measured ${it.value}. ${WHY[it.id] ?: ""}".trim(),
                how = it.tip,
                drill = drill(it.id),
            )
        }
        val score = result.score
        val name = result.title.lowercase()
        val summary = when {
            score == null -> "Not enough of your body was visible to score this $name. Film side-on with your whole body in frame."
            score >= 85 -> "Strong $name ($score/100). Keep grooving it."
            score >= 60 -> "Solid $name ($score/100) with a couple of things to tidy up."
            else -> "${result.title} score $score/100. Work on the fixes below one at a time."
        }
        return CoachReport(
            summary = summary,
            measurementReview = lowConfidenceReviews(result, hand),
            strengths = result.checks.filter { it.status == Status.GOOD }.map { it.label },
            improvements = improvements,
            nextSessionFocus = improvements.firstOrNull()?.let { "${it.title}: ${it.how}" }
                ?: "Keep the same motion and build consistency.",
        )
    }

    fun ruleBased(result: ServeResult, hand: Handedness) = ruleBased(result.stroke, hand)

    /** Checks measured from joints the tracker could barely see. Always flagged, whatever a model says. */
    internal fun lowConfidenceReviews(result: StrokeResult, hand: Handedness) = result.evaluations.flatMap { eval ->
        val frame = result.frame(eval.phase) ?: return@flatMap emptyList()
        eval.checks.filter { it.status != Status.UNKNOWN && confidenceLabel(frame.pose, it.id, hand) == "low" }
            .map { CoachReport.MeasurementReview(it.id, false, "The tracker couldn't see these joints clearly, so this may be off.") }
    }

    fun drill(checkId: String) = DRILLS[checkId] ?: "Shadow-swing slowly in front of a mirror, pausing on this position."

    // Language-model prompts — keep identical to Coach.swift.

    val instructions = """
        You are an experienced, encouraging tennis coach. A phone's pose tracker measured a recreational player's tennis stroke at its key moments and graded each check good, warn or bad.

        Each check lists the measured value, the target, the grade, how confident the tracker was, and the analyzer's note. The analyzer's note tells you which way to fix it: trust it for direction.

        Pose tracking from one camera can be wrong. In measurement_review, list only the checks whose measurement is untrustworthy: its tracker confidence is low, the value is physically implausible, or the photos clearly show something different. Use the check's id exactly as written in the square brackets and keep each note under 15 words. An empty list is fine.

        Then coach: list what the player already does well (checks graded good) and give at most three improvements for checks graded bad or warn, the most important first. Each improvement has a short title, why it matters, a short on-court cue, and one simple drill that is different from the cue. Base advice only on trustworthy measurements. Use plain, friendly language and keep every field to one or two sentences. Reply with JSON only.
    """.trimIndent()

    /** The user turn: measurements, tracker confidence, and the rule-based plan to build on. */
    fun prompt(result: StrokeResult, hand: Handedness, hasImages: Boolean): String {
        val lines = mutableListOf<String>()
        if (hasImages) {
            val order = result.keyFrames.joinToString(", ") { it.phase.title.lowercase() }
            lines += "The images show the ${result.title.lowercase()} in order: $order. Check the measurements against what you see."
        }
        lines += "Stroke: ${result.title}. Player is ${if (hand == Handedness.RIGHT) "right" else "left"}-handed."
        for (phase in result.type.phases) {
            val eval = result.evaluation(phase)
            if (eval == null) {
                lines += ""
                lines += "No ${phase.title.lowercase()} was found."
                continue
            }
            val frame = result.frame(phase)
            lines += ""
            lines += "${phase.title}, score ${eval.score ?: "n/a"}/100"
            for (c in eval.checks) {
                val confidence = frame?.let { confidenceLabel(it.pose, c.id, hand) } ?: "unknown"
                lines += "- [${c.id}] ${c.label}: measured ${c.value}, target ${TARGETS[c.id] ?: "n/a"}, graded ${c.status.name.lowercase()}, tracker confidence $confidence. Analyzer note: ${c.tip}"
            }
        }
        val plan = ruleBased(result, hand)
        if (plan.improvements.isNotEmpty()) {
            lines += ""
            lines += "Suggested drills you may use or improve on:"
            for (item in plan.improvements) lines += "- ${item.title}: ${item.drill}"
        }
        return lines.joinToString("\n")
    }

    fun prompt(result: ServeResult, hand: Handedness, hasImages: Boolean) = prompt(result.stroke, hand, hasImages)

    /**
     * JSON schema for constrained decoding; keys match the Swift schema. The minimum lengths matter:
     * without them the decoder is free to emit empty strings, and small models do.
     */
    val schema = """
        {"type":"object","properties":{
        "summary":{"type":"string","minLength":20},
        "measurement_review":{"type":"array","items":{"type":"object","properties":{
        "check_id":{"type":"string"},"trustworthy":{"type":"boolean"},"note":{"type":"string","minLength":5}},
        "required":["check_id","trustworthy","note"]}},
        "strengths":{"type":"array","items":{"type":"string","minLength":5}},
        "improvements":{"type":"array","maxItems":3,"items":{"type":"object","properties":{
        "title":{"type":"string","minLength":3},"why":{"type":"string","minLength":10},
        "how":{"type":"string","minLength":10},"drill":{"type":"string","minLength":10}},
        "required":["title","why","how","drill"]}},
        "next_session_focus":{"type":"string","minLength":10}},
        "required":["summary","measurement_review","strengths","improvements","next_session_focus"]}
    """.trimIndent().replace("\n", "")

    /** Parse a model's JSON reply about one stroke. Null if it can't be used, so callers fall back to the rules. */
    fun parse(text: String, result: StrokeResult, hand: Handedness, modelName: String): CoachReport? {
        val plan = ruleBased(result, hand)
        return parse(text, result.checks.map { it.id }.toSet(), plan, modelName, forcedReviews = plan.measurementReview)
    }

    fun parse(text: String, result: ServeResult, hand: Handedness, modelName: String) = parse(text, result.stroke, hand, modelName)

    // Match coaching

    val matchInstructions = """
        You are an experienced, encouraging tennis coach reviewing a recreational player's match video. A phone tracked the player's body and summarised each kind of stroke (how many, the average score out of 100 and the goal most often missed, with its fix), plus footwork estimates. Stroke types are detected automatically from body position and can occasionally be wrong, and footwork numbers are estimates.

        Write a short summary of the match, list what the player does well, and give at most three improvements, the most important first. Each improvement has a short title, why it matters, a short on-court cue, and one simple drill that is different from the cue. Only list strengths from the "Doing well" list, base the improvements on the suggested priorities in that order, and never invent numbers or habits that aren't in the data. Leave measurement_review empty. Use plain, friendly language, keep every field to one or two sentences, and reply with JSON only.
    """.trimIndent()

    /** Coaching for a whole match, built from the stroke summaries and footwork. */
    fun ruleBased(match: MatchReport): CoachReport {
        val ranked = match.summaries.filter { it.averageScore != null }.sortedBy { it.averageScore }
        val improvements = mutableListOf<CoachReport.Improvement>()
        fun strokeFix(s: StrokeSummary) {
            val fix = s.commonFix ?: return
            val avg = s.averageScore ?: return
            if (avg >= 85) return
            improvements += CoachReport.Improvement(
                title = "${s.type.title}: ${fix.label.lowercase()}",
                why = "Your ${s.type.title.lowercase()}s averaged $avg/100 and this was the most common problem. ${WHY[fix.id] ?: ""}".trim(),
                how = fix.tip,
                drill = drill(fix.id),
            )
        }
        ranked.firstOrNull()?.let(::strokeFix)
        match.splitStepRate?.takeIf { it < 0.5 }?.let {
            improvements += CoachReport.Improvement(
                title = "Split step before every shot",
                why = "A small hop as your opponent hits lets you push off quickly in either direction. ${WHY.getValue("split-step")}",
                how = "Hop lightly onto the balls of your feet just as your opponent swings.",
                drill = drill("split-step"),
            )
        }
        match.readyStanceRate?.takeIf { it < 0.5 }?.let {
            improvements += CoachReport.Improvement(
                title = "Stay low between shots",
                why = "With straight legs you lose the first step to the ball. ${WHY.getValue("ready-knees")}",
                how = "Keep your knees bent and the racket up in front of you while you wait.",
                drill = drill("ready-knees"),
            )
        }
        for (s in ranked.drop(1)) if (improvements.size < 3) strokeFix(s)

        val strengths = match.summaries.mapNotNull { s ->
            val avg = s.averageScore ?: return@mapNotNull null
            if (avg >= 75) "Solid ${s.type.title.lowercase()}s (average $avg/100)" else null
        }.toMutableList()
        if ((match.splitStepRate ?: 0.0) >= 0.7) strengths += "Good split-step habit"
        if ((match.readyStanceRate ?: 0.0) >= 0.7) strengths += "Athletic ready stance between shots"

        var summary = match.countsText
        match.score?.let { summary += ", average score $it/100" }
        summary += "."
        val best = ranked.lastOrNull()
        val worst = ranked.firstOrNull()
        if (best != null && worst != null && best.type != worst.type) {
            summary += " Your best stroke was the ${best.type.title.lowercase()}; the biggest gain is in your ${worst.type.title.lowercase()}."
        }
        if (match.strokes.isEmpty()) {
            summary = "No strokes were found. Film from the side with your whole body in frame, and keep the camera still."
        }
        val plan = improvements.take(3)
        return CoachReport(
            summary = summary,
            measurementReview = emptyList(),
            strengths = strengths,
            improvements = plan,
            nextSessionFocus = plan.firstOrNull()?.let { "${it.title}: ${it.how}" } ?: "Keep playing the same way and build consistency.",
        )
    }

    /** The user turn for match coaching. */
    fun matchPrompt(match: MatchReport, hand: Handedness): String {
        val minutes = match.duration.toInt() / 60
        val seconds = match.duration.toInt() % 60
        val lines = mutableListOf(
            "Player is ${if (hand == Handedness.RIGHT) "right" else "left"}-handed. Video length $minutes min $seconds s. ${match.countsText}.",
            "",
            "Strokes:",
        )
        for (s in match.summaries) {
            var line = "- ${s.type.title}: ${s.count} hit, average score ${s.averageScore?.let { "$it/100" } ?: "n/a"}"
            // Name the check as a goal not met, then the fix, so the model can't read the goal as the problem.
            s.commonFix?.let { line += ". Most often missed: \"${it.label}\" (graded ${it.status.name.lowercase()}). The fix: ${it.tip}" }
            lines += line
        }
        if (match.summaries.isEmpty()) lines += "- none found"
        lines += ""
        lines += "Footwork:"
        match.splitStepRate?.let { lines += "- Split step before ${Math.round(it * 100)}% of groundstrokes and volleys (target: every shot)." }
        match.readyStanceRate?.let { lines += "- Knees-bent ready stance ${Math.round(it * 100)}% of the time between shots (target: most of the time)." }
        match.movementMeters?.takeIf { it >= 1 }?.let { lines += "- About ${Math.round(it)} m of side-to-side movement." }

        val plan = ruleBased(match)
        lines += ""
        lines += "Doing well:"
        lines += if (plan.strengths.isEmpty()) listOf("- nothing stands out yet") else plan.strengths.map { "- $it" }
        if (plan.improvements.isNotEmpty()) {
            lines += ""
            lines += "Suggested priorities you may use or improve on:"
            for (item in plan.improvements) lines += "- ${item.title}: ${item.drill}"
        }
        return lines.joinToString("\n")
    }

    fun parse(text: String, match: MatchReport, modelName: String): CoachReport? {
        val plan = ruleBased(match)
        // Strengths come from the measured data only, so the model can't praise habits it didn't see.
        return parse(text, emptySet(), plan, modelName, fixedStrengths = plan.strengths)
    }

    // Parsing

    /**
     * Parse a model's JSON reply, tolerating surrounding text or code fences, and clean it up.
     * [known] lists the check ids it may review; [plan] fills in anything left blank; [forcedReviews]
     * override the model's own reviews; [fixedStrengths] replace the model's strengths.
     */
    internal fun parse(
        text: String, known: Set<String>, plan: CoachReport, modelName: String,
        forcedReviews: List<CoachReport.MeasurementReview> = emptyList(), fixedStrengths: List<String>? = null,
    ): CoachReport? {
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start < 0 || end <= start) return null
        val obj = runCatching { Json.parseToJsonElement(text.substring(start, end + 1)).jsonObject }.getOrNull() ?: return null

        fun JsonObject.str(key: String) = runCatching { this[key]?.jsonPrimitive?.contentOrNull }.getOrNull()?.trim().orEmpty()
        fun JsonObject.arr(key: String) = runCatching { this[key]?.jsonArray }.getOrNull() ?: JsonArray(emptyList())

        val reviews = obj.arr("measurement_review").mapNotNull { el ->
            val r = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
            val id = normalizeId(r.str("check_id"))
            // Drop reviews of checks that don't exist (small models sometimes invent them).
            if (id !in known) return@mapNotNull null
            val trustworthy = runCatching { r["trustworthy"]?.jsonPrimitive?.booleanOrNull }.getOrNull() ?: true
            CoachReport.MeasurementReview(id, trustworthy, r.str("note"))
        }
        val improvements = obj.arr("improvements").mapNotNull { el ->
            runCatching { el.jsonObject }.getOrNull()
        }.take(3).mapIndexedNotNull { index, i ->
            // Fill any blank field from the analyzer's plan, which is in the same priority order.
            val fallback = plan.improvements.getOrNull(index)
            val title = i.str("title").ifBlank { fallback?.title.orEmpty() }
            // Models sometimes repeat the drill inside the cue.
            val how = i.str("how").removePrefix("Cue:").substringBefore("Drill:").trim().ifBlank { fallback?.how.orEmpty() }
            if (title.isBlank() || how.isBlank()) return@mapIndexedNotNull null
            CoachReport.Improvement(
                title = title,
                why = i.str("why").ifBlank { fallback?.why.orEmpty() },
                how = how,
                drill = i.str("drill").ifBlank { fallback?.drill ?: drill("") },
            )
        }
        val strengths = obj.arr("strengths").mapNotNull { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull()?.trim() }
            .filter { it.isNotBlank() }.take(5)
        val summary = obj.str("summary")
        if (summary.isBlank() && improvements.isEmpty()) return null
        // A summary holding JSON or an essay means the model lost the format; don't show it.
        if ('{' in summary || summary.length > 800) return null

        return CoachReport(
            summary = summary.ifBlank { plan.summary },
            measurementReview = mergeReviews(reviews, forcedReviews),
            strengths = fixedStrengths ?: strengths,
            improvements = improvements,
            nextSessionFocus = obj.str("next_session_focus").ifBlank { improvements.firstOrNull()?.title ?: plan.nextSessionFocus },
            source = CoachSource.ON_DEVICE_AI,
            modelName = modelName,
        )
    }

    /** The model's reviews in order, one per check, with [forced] ones replacing or added to them. */
    internal fun mergeReviews(reviews: List<CoachReport.MeasurementReview>, forced: List<CoachReport.MeasurementReview>): List<CoachReport.MeasurementReview> {
        val merged = reviews.distinctBy { it.checkId }.map { r -> forced.firstOrNull { it.checkId == r.checkId } ?: r }
        val seen = merged.map { it.checkId }.toSet()
        return merged + forced.filter { it.checkId !in seen }
    }

    /** Models sometimes echo ids as "id knee-bend", "[knee-bend]" or "knee_bend". */
    internal fun normalizeId(raw: String) =
        raw.trim().removePrefix("id ").trim().trim('[', ']', '`', '"').trim().lowercase().replace('_', '-')

    /** How confident the tracker was in the joints a check uses: high, medium or low. */
    fun confidenceLabel(pose: Pose, checkId: String, hand: Handedness): String {
        val (hit, toss) = if (hand == Handedness.RIGHT) "RIGHT" to "LEFT" else "LEFT" to "RIGHT"
        fun j(side: String, part: String) = Joint.valueOf("${side}_$part")
        val joints = when (checkId) {
            "toss-arm-straight", "toss-arm-tuck" -> listOf(j(toss, "SHOULDER"), j(toss, "ELBOW"), j(toss, "WRIST"))
            "toss-arm-high" -> listOf(j(toss, "WRIST"), Joint.NOSE)
            "hit-elbow-bend", "hit-arm-extended" -> listOf(j(hit, "SHOULDER"), j(hit, "ELBOW"), j(hit, "WRIST"))
            "hit-elbow-height" -> listOf(j(hit, "SHOULDER"), j(hit, "ELBOW"))
            "contact-height" -> listOf(j(hit, "WRIST"), Joint.NOSE)
            "shoulder-tilt" -> listOf(Joint.LEFT_SHOULDER, Joint.RIGHT_SHOULDER)
            "torso-upright" -> listOf(Joint.LEFT_SHOULDER, Joint.RIGHT_SHOULDER, Joint.LEFT_HIP, Joint.RIGHT_HIP)
            "knee-bend", "leg-drive", "prep-knees", "ready-knees" ->
                listOf(Joint.LEFT_HIP, Joint.RIGHT_HIP, Joint.LEFT_KNEE, Joint.RIGHT_KNEE, Joint.LEFT_ANKLE, Joint.RIGHT_ANKLE)
            "contact-spacing", "volley-firm" -> listOf(j(hit, "SHOULDER"), j(hit, "ELBOW"), j(hit, "WRIST"))
            "prep-takeback", "volley-compact", "finish-high" -> listOf(j(hit, "WRIST"), Joint.LEFT_SHOULDER, Joint.RIGHT_SHOULDER)
            "contact-in-front", "strike-zone", "volley-hands-up" -> listOf(j(hit, "WRIST"), Joint.LEFT_HIP, Joint.RIGHT_HIP)
            "finish-through", "volley-short" -> listOf(j(hit, "WRIST"))
            "prep-stance", "ready-stance" -> listOf(Joint.LEFT_ANKLE, Joint.RIGHT_ANKLE)
            "prep-off-arm" -> listOf(j(toss, "WRIST"), Joint.LEFT_SHOULDER, Joint.RIGHT_SHOULDER)
            "oh-off-arm-up" -> listOf(j(toss, "WRIST"), Joint.NOSE)
            "oh-racket-up" -> listOf(j(hit, "SHOULDER"), j(hit, "ELBOW"))
            "oh-contact-high" -> listOf(j(hit, "WRIST"), Joint.NOSE)
            "contact-balance", "finish-balance" -> listOf(Joint.LEFT_SHOULDER, Joint.RIGHT_SHOULDER, Joint.LEFT_HIP, Joint.RIGHT_HIP)
            "ready-hands" -> listOf(Joint.LEFT_WRIST, Joint.RIGHT_WRIST, Joint.LEFT_HIP, Joint.RIGHT_HIP)
            else -> return "unknown"
        }
        val lowest = joints.minOf { pose.joints[it]?.confidence ?: 0.0 }
        return when {
            lowest >= 0.7 -> "high"
            lowest >= 0.5 -> "medium"
            else -> "low"
        }
    }

    // Coaching content — keep in sync with Coach.swift.

    private val TARGETS = mapOf(
        "toss-arm-straight" to "155–180°",
        "toss-arm-high" to "at least 0.60× torso above the nose",
        "hit-elbow-bend" to "70–115°",
        "hit-elbow-height" to "at or above shoulder height",
        "shoulder-tilt" to "at least 0.12× torso",
        "knee-bend" to "110–155°",
        "hit-arm-extended" to "160–180°",
        "contact-height" to "at least 0.90× torso above the nose",
        "leg-drive" to "160–180°",
        "torso-upright" to "20° or less",
        "toss-arm-tuck" to "tucked",
        "prep-takeback" to "at least 0.50× torso behind the shoulders",
        "prep-knees" to "110–160°",
        "prep-stance" to "at least 0.90× torso between the ankles",
        "prep-off-arm" to "at least 0.15× torso in front of the shoulders",
        "contact-in-front" to "at least 0.20× torso in front of the hips (0.30× on volleys)",
        "contact-spacing" to "110–180° (150–180° on a one-handed backhand)",
        "strike-zone" to "between 0.30× torso below and 0.90× torso above the hips",
        "contact-balance" to "20° or less",
        "finish-high" to "at or above shoulder height",
        "finish-through" to "at least 2.0× torso of hand travel",
        "finish-balance" to "20° or less",
        "volley-compact" to "0.40× torso or less behind the shoulders",
        "volley-hands-up" to "at least 0.30× torso above the hips",
        "volley-firm" to "100–170°",
        "volley-short" to "1.2× torso or less of hand travel",
        "oh-off-arm-up" to "at least 0.30× torso above the nose",
        "oh-racket-up" to "at or above shoulder height",
        "oh-contact-high" to "at least 0.70× torso above the nose",
        "ready-knees" to "120–165°",
        "ready-stance" to "at least 0.90× torso between the ankles",
        "ready-hands" to "both hands above the waist",
    )

    private val WHY = mapOf(
        "toss-arm-straight" to "A straight tossing arm gives a consistent, repeatable toss.",
        "toss-arm-high" to "A high release keeps the ball on line and lifts your front side.",
        "hit-elbow-bend" to "The 'L' stores energy for the racket drop and a fast swing up.",
        "hit-elbow-height" to "A low elbow costs racket speed and puts stress on the shoulder.",
        "shoulder-tilt" to "The tilt lets you swing up to the ball instead of across it.",
        "knee-bend" to "Loaded legs are where most of the serve's power starts.",
        "hit-arm-extended" to "Full extension means a higher contact point and more margin over the net.",
        "contact-height" to "Higher contact opens up the service box.",
        "leg-drive" to "Driving up transfers your leg power into the racket.",
        "torso-upright" to "Leaning sideways usually means the toss drifted and costs balance.",
        "toss-arm-tuck" to "Tucking the tossing arm speeds up your shoulder rotation.",
        "prep-takeback" to "An early turn gives you time and lets you swing smoothly instead of rushing.",
        "prep-knees" to "Bent knees let you push up into the ball for free power and better balance.",
        "prep-stance" to "A wide base keeps you stable while you rotate.",
        "prep-off-arm" to "The non-hitting arm drives the shoulder turn and helps you judge the ball.",
        "contact-in-front" to "Hitting in front lets your body weight go into the shot and gives you control.",
        "contact-spacing" to "The right spacing lets you swing freely instead of getting jammed.",
        "strike-zone" to "Between waist and chest is where you can swing hardest with control.",
        "contact-balance" to "Balance at contact keeps your shots consistent.",
        "finish-high" to "A high finish means you swung up through the ball, which adds topspin and net clearance.",
        "finish-through" to "Swinging through the ball keeps the racket face stable and adds depth.",
        "finish-balance" to "Finishing balanced means you're ready for the next shot sooner.",
        "volley-compact" to "There's no time for a big swing at the net; a short backswing keeps you on time.",
        "volley-hands-up" to "Starting with the racket up saves time and keeps the volley firm.",
        "volley-firm" to "A firm arm lets you use the ball's pace instead of swinging.",
        "volley-short" to "A short punch keeps the volley controlled and in the court.",
        "oh-off-arm-up" to "Pointing at the ball lines up the overhead and keeps your head up.",
        "oh-racket-up" to "Getting the racket up early gives you time to hit at the top of your reach.",
        "oh-contact-high" to "Hitting at full reach gives you the best angle down into the court.",
        "ready-knees" to "Bent knees let you take your first step to the ball faster.",
        "ready-stance" to "A wide stance lets you push off in either direction.",
        "ready-hands" to "A racket held up in front is ready for both forehands and backhands.",
        "split-step" to "It's the single biggest footwork habit that separates good players.",
    )

    private val DRILLS = mapOf(
        "toss-arm-straight" to "Toss 10 balls without hitting, keeping the arm straight, so each ball lands on a racket laid in front of you.",
        "toss-arm-high" to "Toss and freeze with your tossing hand pointing at the ball for 2 seconds before letting it drop.",
        "hit-elbow-bend" to "From the trophy position, hold the racket behind you with the elbow at 90° for 3 seconds, 10 reps.",
        "hit-elbow-height" to "Shadow-serve in front of a mirror and check your hitting elbow reaches shoulder height before you swing.",
        "shoulder-tilt" to "Point your tossing hand at the ball and feel the front shoulder rise as the back shoulder drops; hold 3 seconds.",
        "knee-bend" to "Do 10 slow trophy-position squats, then jump up through an imaginary ball.",
        "hit-arm-extended" to "Serve at a high target (top of the fence or a partner's raised hand) and reach to touch it at full stretch.",
        "contact-height" to "Toss slightly higher and practise hitting at the very peak of your reach, 10 balls.",
        "leg-drive" to "Serve focusing only on pushing up off the ground so you land inside the court.",
        "torso-upright" to "Toss so the ball would land a foot inside the baseline, and stay tall through contact.",
        "toss-arm-tuck" to "Shadow-serve pulling the tossing hand into your stomach as the racket goes up.",
        "prep-takeback" to "Have a partner feed balls and call 'turn' as the ball crosses the net; be fully turned before it bounces.",
        "prep-knees" to "Shadow-swing 10 times, sitting slightly into your legs on the turn and pushing up into the swing.",
        "prep-stance" to "Rally with a racket-length gap marked between your feet with two balls, keeping that width for every shot.",
        "prep-off-arm" to "Shadow forehands catching an imaginary ball with your non-hitting hand as you turn.",
        "contact-in-front" to "Drop-feed balls to yourself and hit them a step in front of your front foot, 15 balls.",
        "contact-spacing" to "Place a ball an arm's length from your hip and shadow-swing to it; then hit drop feeds at that spacing.",
        "strike-zone" to "Rally aiming to let every ball drop to waist height before you hit; move back or bend to make it happen.",
        "contact-balance" to "Hit 10 forehands and freeze at contact, checking your head is over your hips.",
        "finish-high" to "Swing and catch the racket throat with your non-hitting hand over your opposite shoulder, 10 reps.",
        "finish-through" to "Shadow-swing slowly, letting the racket finish all the way around your body, then speed up.",
        "finish-balance" to "Hit 10 balls and hold each finish for two seconds before relaxing.",
        "volley-compact" to "Stand with your back near a fence and volley partner feeds; the fence stops a big backswing.",
        "volley-hands-up" to "Volley partner feeds while keeping the racket head above your hands the whole time.",
        "volley-firm" to "Catch-and-push drill: let the ball meet your strings and push it forward without swinging, 20 balls.",
        "volley-short" to "Volley feeds and stop the racket as soon as you make contact, like catching the ball.",
        "oh-off-arm-up" to "Have a partner lob 10 balls; point at each one with your non-hitting hand until you swing.",
        "oh-racket-up" to "From a sideways stance, practise lifting the racket straight into the trophy position as the lob goes up.",
        "oh-contact-high" to "Practise quick side-steps back under lobs so you can hit each one at full reach.",
        "ready-knees" to "Between every shot in a rally, bounce lightly with your knees bent until the ball is struck.",
        "ready-stance" to "Shadow-play: return to a wide, balanced stance with racket up after every swing.",
        "ready-hands" to "Rally holding the racket throat with your non-hitting hand between every shot.",
        "split-step" to "Rally and say 'hop' out loud each time your partner hits; land on the balls of your feet as they make contact.",
    )
}
