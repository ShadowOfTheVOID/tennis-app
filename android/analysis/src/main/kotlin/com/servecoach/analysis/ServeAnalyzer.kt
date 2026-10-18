package com.servecoach.analysis

import kotlin.math.roundToInt

enum class Phase(val title: String) {
    READY("Ready"),
    TROPHY("Trophy position"),
    CONTACT("Contact"),
}

enum class Status(internal val points: Double?) {
    GOOD(1.0), WARN(0.5), BAD(0.0), UNKNOWN(null)
}

data class Check(
    val id: String,
    val label: String,
    val status: Status,
    /** Measured value, formatted for display (e.g. "95°"). */
    val value: String,
    val tip: String,
)

data class Evaluation(val phase: Phase, val checks: List<Check>) {
    /** 0–100 over the checks that could be measured, or null if none could. */
    val score: Int?
        get() {
            val pts = checks.mapNotNull { it.status.points }
            if (pts.isEmpty()) return null
            return (pts.sum() / pts.size * 100).roundToInt()
        }
}

data class Frame(val time: Double, val pose: Pose)

/** Mirrors `ServeAnalyzer` in the Swift package; keep thresholds and tips in sync. */
object ServeAnalyzer {
    // Phase detection

    /** Classify which part of the serve a single pose looks like. */
    fun phase(pose: Pose, hand: Handedness): Phase {
        val (hit, toss) = pose.sides(hand)
        val nose = pose[Joint.NOSE] ?: return Phase.READY
        val t = pose.torsoLength ?: return Phase.READY
        val sh = hit.shoulder ?: return Phase.READY
        val el = hit.elbow ?: return Phase.READY
        val wr = hit.wrist ?: return Phase.READY
        if (nose.y - wr.y > 0.4 * t && Geometry.angle(sh, el, wr) > 145) return Phase.CONTACT
        val tw = toss.wrist
        if (tw != null && tw.y < nose.y) return Phase.TROPHY
        return Phase.READY
    }

    fun evaluate(pose: Pose, hand: Handedness): Evaluation? = when (phase(pose, hand)) {
        Phase.TROPHY -> trophy(pose, hand)
        Phase.CONTACT -> contact(pose, hand)
        Phase.READY -> null
    }

    // Trophy position

    fun trophy(pose: Pose, hand: Handedness): Evaluation {
        val (hit, toss) = pose.sides(hand)
        val t = pose.torsoLength
        val nose = pose[Joint.NOSE]
        val checks = mutableListOf<Check>()

        checks += measure("toss-arm-straight", "Tossing arm straight", toss.shoulder, toss.elbow, toss.wrist) { s, e, w ->
            val a = Geometry.angle(s, e, w)
            val status = band(a, 155.0..180.0, 135.0..180.0)
            Triple(status, deg(a), if (status == Status.GOOD) "Nice, long tossing arm."
            else "Keep the tossing arm straight and lift from the shoulder — don't flick from the elbow.")
        }

        checks += if (toss.wrist != null && nose != null && t != null) {
            val h = (nose.y - toss.wrist.y) / t
            val status = if (h >= 0.6) Status.GOOD else if (h >= 0.2) Status.WARN else Status.BAD
            Check("toss-arm-high", "Tossing arm reaching up", status, torso(h),
                if (status == Status.GOOD) "Tossing hand is reaching high."
                else "Release higher — finish the toss with your hand pointing up at the ball.")
        } else unknown("toss-arm-high", "Tossing arm reaching up")

        checks += measure("hit-elbow-bend", "Hitting elbow ~90°", hit.shoulder, hit.elbow, hit.wrist) { s, e, w ->
            val a = Geometry.angle(s, e, w)
            val status = band(a, 70.0..115.0, 55.0..135.0)
            val tip = when {
                status == Status.GOOD -> "Good 'L' shape in the hitting arm."
                a > 115 -> "Bend the hitting elbow more — make an 'L' with the racket up behind you."
                else -> "Hitting elbow is too closed — open it toward a 90° 'L'."
            }
            Triple(status, deg(a), tip)
        }

        checks += if (hit.shoulder != null && hit.elbow != null && t != null) {
            val drop = (hit.elbow.y - hit.shoulder.y) / t
            val status = if (drop <= 0.1) Status.GOOD else if (drop <= 0.3) Status.WARN else Status.BAD
            Check("hit-elbow-height", "Hitting elbow at shoulder height", status,
                if (drop <= 0) "above" else "${torso(drop)} below",
                if (status == Status.GOOD) "Elbow is up where it should be."
                else "Raise the hitting elbow to about shoulder height — a low elbow costs power and strains the shoulder.")
        } else unknown("hit-elbow-height", "Hitting elbow at shoulder height")

        checks += if (hit.shoulder != null && toss.shoulder != null && t != null) {
            val tilt = (hit.shoulder.y - toss.shoulder.y) / t
            val status = if (tilt >= 0.12) Status.GOOD else if (tilt >= 0.04) Status.WARN else Status.BAD
            Check("shoulder-tilt", "Shoulders tilted toward the toss", status, torso(tilt),
                if (status == Status.GOOD) "Great shoulder-over-shoulder tilt."
                else "Let the tossing shoulder rise above the hitting shoulder — tilt like a seesaw.")
        } else unknown("shoulder-tilt", "Shoulders tilted toward the toss")

        val k = kneeAngle(pose)
        checks += if (k != null) {
            val status = band(k, 110.0..155.0, 95.0..168.0)
            val tip = when {
                status == Status.GOOD -> "Legs are loaded and ready to drive."
                k > 155 -> "Bend your knees more to load up — the serve starts from the legs."
                else -> "That's a very deep bend — you may lose balance. Aim for a moderate squat."
            }
            Check("knee-bend", "Knees loaded", status, deg(k), tip)
        } else unknown("knee-bend", "Knees loaded")

        return Evaluation(Phase.TROPHY, checks)
    }

    // Contact

    fun contact(pose: Pose, hand: Handedness): Evaluation {
        val (hit, toss) = pose.sides(hand)
        val t = pose.torsoLength
        val nose = pose[Joint.NOSE]
        val checks = mutableListOf<Check>()

        checks += measure("hit-arm-extended", "Hitting arm fully extended", hit.shoulder, hit.elbow, hit.wrist) { s, e, w ->
            val a = Geometry.angle(s, e, w)
            val status = band(a, 160.0..180.0, 145.0..180.0)
            Triple(status, deg(a), if (status == Status.GOOD) "Full reach at contact."
            else "Reach up and hit at full extension — don't let the ball drop into you.")
        }

        checks += if (hit.wrist != null && nose != null && t != null) {
            val h = (nose.y - hit.wrist.y) / t
            val status = if (h >= 0.9) Status.GOOD else if (h >= 0.6) Status.WARN else Status.BAD
            Check("contact-height", "High contact point", status, torso(h),
                if (status == Status.GOOD) "Contact point is nice and high."
                else "Contact the ball higher — toss a bit higher and drive up through it.")
        } else unknown("contact-height", "High contact point")

        val k = kneeAngle(pose)
        checks += if (k != null) {
            val status = band(k, 160.0..180.0, 145.0..180.0)
            Check("leg-drive", "Legs extended (leg drive)", status, deg(k),
                if (status == Status.GOOD) "You drove up through your legs."
                else "Push up through the ground so your legs are straight by contact.")
        } else unknown("leg-drive", "Legs extended (leg drive)")

        val ls = pose[Joint.LEFT_SHOULDER]
        val rs = pose[Joint.RIGHT_SHOULDER]
        val lh = pose[Joint.LEFT_HIP]
        val rh = pose[Joint.RIGHT_HIP]
        checks += if (ls != null && rs != null && lh != null && rh != null) {
            val lean = Geometry.leanFromVertical(Geometry.midpoint(lh, rh), Geometry.midpoint(ls, rs))
            val status = band(lean, 0.0..20.0, 0.0..32.0)
            Check("torso-upright", "Torso tall and balanced", status, deg(lean),
                if (status == Status.GOOD) "Tall, balanced posture through contact."
                else "You're leaning a lot — keep the toss in front and stay tall instead of bending sideways.")
        } else unknown("torso-upright", "Torso tall and balanced")

        checks += if (toss.wrist != null && toss.shoulder != null && t != null) {
            val tucked = toss.wrist.y > toss.shoulder.y - 0.1 * t
            Check("toss-arm-tuck", "Tossing arm tucked in", if (tucked) Status.GOOD else Status.WARN,
                if (tucked) "tucked" else "still up",
                if (tucked) "Tossing arm pulled in — that helps you rotate."
                else "Pull the tossing arm down into your chest as you swing up to speed up rotation.")
        } else unknown("toss-arm-tuck", "Tossing arm tucked in")

        return Evaluation(Phase.CONTACT, checks)
    }

    // Recorded serves

    /**
     * Find the trophy and contact frames in a recorded serve.
     * Contact: the hitting wrist at its highest relative to the head.
     * Trophy: the tossing wrist at its highest before contact.
     */
    fun keyFrames(frames: List<Frame>, hand: Handedness): Pair<Frame?, Frame?> {
        fun height(f: Frame, wrist: Point?): Double? {
            val nose = f.pose[Joint.NOSE] ?: return null
            val t = f.pose.torsoLength ?: return null
            return (nose.y - (wrist ?: return null).y) / t
        }
        val contact = frames
            .mapNotNull { f -> height(f, f.pose.sides(hand).first.wrist)?.let { f to it } }
            .maxByOrNull { it.second }?.first
        val contactTime = contact?.time ?: Double.POSITIVE_INFINITY
        val trophy = frames
            .filter { it.time < contactTime }
            .mapNotNull { f -> height(f, f.pose.sides(hand).second.wrist)?.let { f to it } }
            .maxByOrNull { it.second }?.first
        return trophy to contact
    }

    fun analyze(frames: List<Frame>, hand: Handedness): ServeResult {
        val (t, c) = keyFrames(frames, hand)
        return ServeResult(t, c, t?.let { trophy(it.pose, hand) }, c?.let { contact(it.pose, hand) })
    }

    // Helpers

    internal fun kneeAngle(pose: Pose): Double? {
        val angles = listOf(Side(pose, left = true), Side(pose, left = false)).mapNotNull { s ->
            val h = s.hip ?: return@mapNotNull null
            val k = s.knee ?: return@mapNotNull null
            val a = s.ankle ?: return@mapNotNull null
            Geometry.angle(h, k, a)
        }
        return if (angles.isEmpty()) null else angles.average()
    }

    private inline fun measure(
        id: String, label: String, a: Point?, b: Point?, c: Point?,
        block: (Point, Point, Point) -> Triple<Status, String, String>,
    ): Check {
        if (a == null || b == null || c == null) return unknown(id, label)
        val (status, value, tip) = block(a, b, c)
        return Check(id, label, status, value, tip)
    }

    private fun band(v: Double, good: ClosedFloatingPointRange<Double>, warn: ClosedFloatingPointRange<Double>) =
        if (v in good) Status.GOOD else if (v in warn) Status.WARN else Status.BAD

    private fun deg(v: Double) = "${v.roundToInt()}°"
    private fun torso(v: Double) = "%.2f× torso".format(java.util.Locale.US, v)

    private fun unknown(id: String, label: String) = Check(id, label, Status.UNKNOWN, "—",
        "Not enough of your body is visible. Step back so your whole body is in frame.")
}
