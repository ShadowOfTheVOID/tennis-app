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
    fun ruleBased(result: ServeResult): CoachReport {
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
        val summary = when {
            score == null -> "Not enough of your body was visible to score this serve. Film side-on with your whole body in frame."
            score >= 85 -> "Strong serve posture ($score/100). Keep grooving it."
            score >= 60 -> "Solid base ($score/100) with a couple of things to tidy up."
            else -> "Score $score/100. Work on the fixes below one at a time."
        }
        return CoachReport(
            summary = summary,
            measurementReview = emptyList(),
            strengths = result.checks.filter { it.status == Status.GOOD }.map { it.label },
            improvements = improvements,
            nextSessionFocus = improvements.firstOrNull()?.let { "${it.title}: ${it.how}" }
                ?: "Keep the same motion and build consistency.",
        )
    }

    fun drill(checkId: String) = DRILLS[checkId] ?: "Shadow-serve slowly in front of a mirror, pausing on this position."

    // Language-model prompts

    val instructions = """
        You are an experienced, encouraging tennis coach. A phone's pose tracker measured a recreational player's serve at two moments, the trophy position and contact, and graded each check good, warn or bad.

        Each check lists the measured value, the target, the grade, how confident the tracker was, and the analyzer's note. The analyzer's note tells you which way to fix it: trust it for direction.

        Pose tracking from one camera can be wrong. For every check, decide whether the measurement is trustworthy: mark it untrustworthy only when its tracker confidence is low, the value is physically implausible, or the photos clearly show something different. Use the check's id exactly as written in the square brackets. Keep each note under 15 words.

        Then coach: list what the player already does well (checks graded good) and give at most three improvements for checks graded bad or warn, the most important first. Each improvement has a short title, why it matters, a short on-court cue, and one simple drill that is different from the cue. Base advice only on trustworthy measurements. Use plain, friendly language and keep every field to one or two sentences. Reply with JSON only.
    """.trimIndent()

    /** The user turn: measurements, tracker confidence, and the rule-based plan to build on. */
    fun prompt(result: ServeResult, hand: Handedness, hasImages: Boolean): String = buildString {
        if (hasImages) appendLine("The first image is the trophy position and the second is contact. Check the measurements against what you see.")
        appendLine("Player is ${if (hand == Handedness.RIGHT) "right" else "left"}-handed.")
        for ((eval, frame) in listOf(result.trophy to result.trophyFrame, result.contact to result.contactFrame)) {
            if (eval == null) continue
            appendLine()
            appendLine("${eval.phase.title}, score ${eval.score ?: "n/a"}/100")
            for (c in eval.checks) {
                val confidence = frame?.let { confidenceLabel(it.pose, c.id, hand) } ?: "unknown"
                appendLine("- [${c.id}] ${c.label}: measured ${c.value}, target ${TARGETS[c.id] ?: "n/a"}, graded ${c.status.name.lowercase()}, tracker confidence $confidence. Analyzer note: ${c.tip}")
            }
        }
        if (result.trophy == null) appendLine("\nNo trophy position was found.")
        if (result.contact == null) appendLine("\nNo contact point was found.")
        val plan = ruleBased(result)
        if (plan.improvements.isNotEmpty()) {
            appendLine("\nSuggested drills you may use or improve on:")
            for (item in plan.improvements) appendLine("- ${item.title}: ${item.drill}")
        }
    }.trimEnd()

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

    /**
     * Parse a model's JSON reply, tolerating surrounding text or code fences, and clean it up.
     * Returns null if it can't be used, so callers fall back to the rule-based coach.
     */
    fun parse(text: String, result: ServeResult, modelName: String): CoachReport? {
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start < 0 || end <= start) return null
        val obj = runCatching { Json.parseToJsonElement(text.substring(start, end + 1)).jsonObject }.getOrNull() ?: return null

        fun JsonObject.str(key: String) = runCatching { this[key]?.jsonPrimitive?.contentOrNull }.getOrNull()?.trim().orEmpty()
        fun JsonObject.arr(key: String) = runCatching { this[key]?.jsonArray }.getOrNull() ?: JsonArray(emptyList())

        val known = result.checks.map { it.id }.toSet()
        val reviews = obj.arr("measurement_review").mapNotNull { el ->
            val r = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
            val id = normalizeId(r.str("check_id"))
            // Drop reviews of checks that don't exist (small models sometimes invent them).
            if (id !in known) return@mapNotNull null
            val trustworthy = runCatching { r["trustworthy"]?.jsonPrimitive?.booleanOrNull }.getOrNull() ?: true
            CoachReport.MeasurementReview(id, trustworthy, r.str("note"))
        }
        val fallback by lazy { ruleBased(result) }
        val improvements = obj.arr("improvements").mapNotNull { el ->
            runCatching { el.jsonObject }.getOrNull()
        }.take(3).mapIndexedNotNull { index, i ->
            // Fill any blank field from the analyzer's plan, which is in the same priority order.
            val plan = fallback.improvements.getOrNull(index)
            val title = i.str("title").ifBlank { plan?.title.orEmpty() }
            val how = i.str("how").removePrefix("Cue:").trim().ifBlank { plan?.how.orEmpty() }
            if (title.isBlank() || how.isBlank()) return@mapIndexedNotNull null
            CoachReport.Improvement(
                title = title,
                why = i.str("why").ifBlank { plan?.why.orEmpty() },
                how = how,
                drill = i.str("drill").ifBlank { plan?.drill ?: drill("") },
            )
        }
        val strengths = obj.arr("strengths").mapNotNull { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull()?.trim() }
            .filter { it.isNotBlank() }.take(5)
        val summary = obj.str("summary")
        if (summary.isBlank() && improvements.isEmpty()) return null
        // A summary holding JSON or an essay means the model lost the format; don't show it.
        if ('{' in summary || summary.length > 800) return null

        return CoachReport(
            summary = summary.ifBlank { fallback.summary },
            measurementReview = reviews,
            strengths = strengths,
            improvements = improvements,
            nextSessionFocus = obj.str("next_session_focus").ifBlank { improvements.firstOrNull()?.title ?: fallback.nextSessionFocus },
            source = CoachSource.ON_DEVICE_AI,
            modelName = modelName,
        )
    }

    /** Models sometimes echo ids as "id knee-bend" or "[knee-bend]". */
    internal fun normalizeId(raw: String) = raw.trim().removePrefix("id ").trim().trim('[', ']', '`', '"').trim().lowercase()

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
            "knee-bend", "leg-drive" -> listOf(Joint.LEFT_HIP, Joint.RIGHT_HIP, Joint.LEFT_KNEE, Joint.RIGHT_KNEE, Joint.LEFT_ANKLE, Joint.RIGHT_ANKLE)
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
    )
}
