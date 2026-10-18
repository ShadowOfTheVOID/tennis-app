package com.servecoach.analysis

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** The strokes the app can coach. Mirrors `StrokeType` in the Swift package. */
enum class StrokeType(val title: String) {
    SERVE("Serve"),
    FOREHAND("Forehand"),
    BACKHAND("Backhand"),
    VOLLEY("Volley"),
    OVERHEAD("Overhead");

    /** The key moments analysed, in order. */
    val phases: List<Phase>
        get() = when (this) {
            SERVE -> listOf(Phase.TROPHY, Phase.CONTACT)
            OVERHEAD -> listOf(Phase.PREPARATION, Phase.CONTACT)
            FOREHAND, BACKHAND, VOLLEY -> listOf(Phase.PREPARATION, Phase.CONTACT, Phase.FINISH)
        }

    /** Lowercase id, matching the Swift raw value. */
    val key: String get() = name.lowercase()
}

data class KeyFrame(val phase: Phase, val frame: Frame)

/** One analysed stroke: its key moments and the checks at each. */
data class StrokeResult(
    val type: StrokeType,
    /** Time of contact (or of the key moment closest to it), in seconds. */
    val time: Double,
    val keyFrames: List<KeyFrame>,
    val evaluations: List<Evaluation>,
    /** Backhand hit with both hands. */
    val twoHanded: Boolean = false,
    /** Whether a split step was seen before the stroke (match analysis only). */
    val splitStep: Boolean? = null,
    /** Peak hitting-hand speed around contact, in metres per second (an estimate of power). */
    val swingSpeed: Double? = null,
    /** +1 when the swing moves right in the image, -1 when it moves left. Used to line up ghost poses. */
    val direction: Double = 1.0,
) {
    /** Serve rhythm: seconds from the trophy position to contact. */
    val tempo: Double?
        get() {
            if (type != StrokeType.SERVE) return null
            val trophy = frame(Phase.TROPHY) ?: return null
            val contact = frame(Phase.CONTACT) ?: return null
            return contact.time - trophy.time
        }

    val title: String get() = if (twoHanded && type == StrokeType.BACKHAND) "Two-handed backhand" else type.title

    fun frame(phase: Phase) = keyFrames.firstOrNull { it.phase == phase }?.frame
    fun evaluation(phase: Phase) = evaluations.firstOrNull { it.phase == phase }

    /** Average of the key moments' scores that could be measured. */
    val score: Int?
        get() {
            val scores = evaluations.mapNotNull { it.score }
            return if (scores.isEmpty()) null else scores.sum() / scores.size
        }

    val checks: List<Check> get() = evaluations.flatMap { it.checks }

    /** The most useful single thing to work on: the first failing check, then the first warning. */
    val topTip: Check? get() = checks.firstOrNull { it.status == Status.BAD } ?: checks.firstOrNull { it.status == Status.WARN }
}

/** The serve as a general stroke, for code that handles every stroke the same way. */
val ServeResult.stroke: StrokeResult
    get() = StrokeResult(
        type = StrokeType.SERVE,
        time = contactFrame?.time ?: trophyFrame?.time ?: 0.0,
        keyFrames = listOfNotNull(trophyFrame?.let { KeyFrame(Phase.TROPHY, it) }, contactFrame?.let { KeyFrame(Phase.CONTACT, it) }),
        evaluations = listOfNotNull(trophy, contact),
        swingSpeed = swingSpeed,
        direction = direction,
    )

/** A fast swing of the hitting arm: almost always a stroke, with contact near the peak speed. */
data class SwingEvent(val index: Int, val time: Double, /** Torso lengths per second. */ val speed: Double)

/**
 * Finds and grades strokes from a sequence of poses. Mirrors `StrokeAnalyzer` in the Swift package;
 * keep thresholds and tips in sync. Assumes the camera films the player side-on.
 */
object StrokeAnalyzer {
    /** Wrist speed (torso lengths per second) that counts as a swing. Walking and bouncing the ball stay well below it. */
    const val MIN_SWING_SPEED = 4.0

    // Finding strokes

    /** Every swing in [frames], in time order. */
    fun swings(frames: List<Frame>, hand: Handedness): List<SwingEvent> {
        if (frames.size < 3) return emptyList()
        val speed = handSpeeds(frames, hand)
        // Peaks: fast enough, and the fastest within 0.6 s either side (ties go to the earlier frame).
        val candidates = speed.indices.filter { i ->
            if (speed[i] < MIN_SWING_SPEED) return@filter false
            var j = i - 1
            while (j >= 0 && frames[i].time - frames[j].time <= 0.6) {
                if (speed[j] >= speed[i]) return@filter false
                j--
            }
            j = i + 1
            while (j < frames.size && frames[j].time - frames[i].time <= 0.6) {
                if (speed[j] > speed[i]) return@filter false
                j++
            }
            true
        }
        val kept = mutableListOf<SwingEvent>()
        for (i in candidates.sortedByDescending { speed[it] }) {
            if (kept.none { abs(it.time - frames[i].time) < 0.9 }) kept += SwingEvent(i, frames[i].time, speed[i])
        }
        return kept.sortedBy { it.time }
    }

    /**
     * Hitting-hand speed at each frame, in torso lengths per second, measured relative to the hips
     * so running across the court isn't mistaken for a swing. Zero where it can't be measured.
     */
    internal fun handSpeeds(frames: List<Frame>, hand: Handedness): DoubleArray {
        val speed = DoubleArray(frames.size)
        if (frames.size < 2) return speed
        val scale = medianTorso(frames) ?: return speed
        val relative = frames.map { f ->
            val w = hitWrist(f.pose, hand)
            val hip = hipMid(f.pose)
            if (w == null || hip == null) null else Point(w.x - hip.x, w.y - hip.y)
        }
        for (i in 1 until frames.size) {
            val a = relative[i - 1] ?: continue
            val b = relative[i] ?: continue
            val dt = frames[i].time - frames[i - 1].time
            if (dt <= 0 || dt >= 0.5) continue
            val step = Geometry.distance(a, b)
            // A one-frame jump that comes straight back is a tracking glitch, not a swing.
            val c = relative.getOrNull(i + 1)
            if (c != null && step > 0 && Geometry.distance(a, c) < 0.5 * step) continue
            speed[i] = step / scale / dt
        }
        return speed
    }

    /**
     * Peak hitting-hand speed within a quarter second of [time], in metres per second. An estimate:
     * it assumes an average 0.5 m shoulder-to-hip length. The racket head moves faster.
     */
    fun handSpeed(frames: List<Frame>, time: Double, hand: Handedness): Double? {
        val speeds = handSpeeds(frames, hand)
        val peak = frames.indices.filter { abs(frames[it].time - time) <= 0.25 }.maxOfOrNull { speeds[it] } ?: 0.0
        return if (peak > 0) peak * MatchAnalyzer.TORSO_METERS else null
    }

    /** Which stroke a swing was, judged from body position alone (no ball or racket tracking). */
    fun classify(frames: List<Frame>, event: SwingEvent, hand: Handedness): Pair<StrokeType, Boolean> {
        val t = event.time
        val scale = medianTorso(frames) ?: 1.0
        val highest = frames.filter { abs(it.time - t) <= 0.3 }.mapNotNull { f ->
            val w = hitWrist(f.pose, hand) ?: return@mapNotNull null
            val nose = f.pose[Joint.NOSE] ?: return@mapNotNull null
            (nose.y - w.y) / scale
        }.maxOrNull() ?: Double.NEGATIVE_INFINITY

        if (highest >= 0.3) {
            // Above the head: a serve starts from standing still with a toss; an overhead doesn't.
            val before = frames.filter { it.time >= t - 2.0 && it.time <= t - 0.6 }
            val moved = pathLength(before.mapNotNull { hipMid(it.pose) }) / scale
            val tossed = frames.any { f ->
                if (f.time < t - 1.5 || f.time >= t - 0.1) return@any false
                val w = tossWrist(f.pose, hand) ?: return@any false
                val nose = f.pose[Joint.NOSE] ?: return@any false
                w.y < nose.y
            }
            return (if (moved <= 0.6 && tossed) StrokeType.SERVE else StrokeType.OVERHEAD) to false
        }

        val contact = frames[event.index]
        val lw = contact.pose[Joint.LEFT_WRIST]
        val rw = contact.pose[Joint.RIGHT_WRIST]
        val twoHanded = lw != null && rw != null && Geometry.distance(lw, rw) / scale <= 0.45
        val d = swingDirection(frames, event, hand)
        val prep = preparationFrame(frames, event, hand, d)
        val backswing = prep?.let { backswingDistance(it.pose, hand, d) } ?: 0.0
        val travel = pathLength(frames.filter { it.time >= t - 0.6 && it.time <= t + 0.4 }.mapNotNull { hitWrist(it.pose, hand) }) / scale
        if (travel < 2.2 && backswing < 0.6) return StrokeType.VOLLEY to false

        // Forehand: the hitting shoulder starts behind (turned away from the net). Backhand: it starts in front.
        val hs = prep?.pose?.get(hitShoulder(hand))
        val ns = prep?.pose?.get(tossShoulder(hand))
        if (hs != null && ns != null && abs((hs.x - ns.x) / scale) >= 0.15) {
            val forehand = (hs.x - ns.x) * d < 0
            return (if (forehand) StrokeType.FOREHAND else StrokeType.BACKHAND) to (!forehand && twoHanded)
        }
        // Shoulders edge-on: fall back to which side of the body the hitting hand met the ball.
        val chs = contact.pose[hitShoulder(hand)]
        val cns = contact.pose[tossShoulder(hand)]
        val w = hitWrist(contact.pose, hand)
        if (chs != null && cns != null && w != null) {
            val mid = Geometry.midpoint(chs, cns)
            val forehand = (w.x - mid.x) * (chs.x - cns.x) >= 0
            return (if (forehand) StrokeType.FOREHAND else StrokeType.BACKHAND) to (!forehand && twoHanded)
        }
        return StrokeType.FOREHAND to false
    }

    /** Analyse the swing at [event] as [type] (or as whatever it looks like when [type] is null). */
    fun analyze(frames: List<Frame>, event: SwingEvent, type: StrokeType? = null, hand: Handedness): StrokeResult {
        val (classified, twoHanded) = classify(frames, event, hand)
        val kind = type ?: classified
        val t = event.time
        if (kind == StrokeType.SERVE) {
            return ServeAnalyzer.analyze(frames.filter { it.time >= t - 2.5 && it.time <= t + 0.3 }, hand).stroke
        }

        val d = swingDirection(frames, event, hand)
        val contact = frames[event.index]
        val keyFrames = mutableListOf<KeyFrame>()
        val evaluations = mutableListOf<Evaluation>()

        if (kind == StrokeType.OVERHEAD) {
            val prep = frames.filter { it.time >= t - 1.5 && it.time <= t - 0.1 }
                .maxByOrNull { height(tossWrist(it.pose, hand), it) }
            if (prep != null) {
                keyFrames += KeyFrame(Phase.PREPARATION, prep)
                evaluations += overheadPreparation(prep.pose, hand)
            }
            keyFrames += KeyFrame(Phase.CONTACT, contact)
            evaluations += overheadContact(contact.pose, hand)
        } else {
            val prep = preparationFrame(frames, event, hand, d)
            val finish = finishFrame(frames, event, hand, volley = kind == StrokeType.VOLLEY)
            val scale = medianTorso(frames) ?: 1.0
            if (prep != null) {
                keyFrames += KeyFrame(Phase.PREPARATION, prep)
                evaluations += preparation(kind, prep.pose, hand, d)
            }
            keyFrames += KeyFrame(Phase.CONTACT, contact)
            evaluations += groundContact(kind, contact.pose, hand, d, twoHanded)
            if (finish != null) {
                val from = if (kind == StrokeType.VOLLEY) contact.time else prep?.time ?: (t - 0.6)
                val path = frames.filter { it.time >= from && it.time <= finish.time }.mapNotNull { hitWrist(it.pose, hand) }
                evaluations += finish(kind, finish.pose, hand, pathLength(path) / scale)
                keyFrames += KeyFrame(Phase.FINISH, finish)
            }
        }
        return StrokeResult(
            kind, t, keyFrames, evaluations, twoHanded = kind == StrokeType.BACKHAND && twoHanded,
            swingSpeed = handSpeed(frames, t, hand), direction = d,
        )
    }

    /** Analyse the fastest swing in a short clip of one stroke. Null if no swing was found. */
    fun analyzeClip(frames: List<Frame>, type: StrokeType? = null, hand: Handedness): StrokeResult? {
        if (type == StrokeType.SERVE) {
            val serve = ServeAnalyzer.analyze(frames, hand)
            return if (serve.contactFrame == null && serve.trophyFrame == null) null else serve.stroke
        }
        val event = swings(frames, hand).maxByOrNull { it.speed } ?: return null
        return analyze(frames, event, type, hand)
    }

    // Ready position

    /** The athletic stance between shots: knees bent, feet wide, racket up in front. */
    fun readyPosition(pose: Pose): Evaluation {
        val checks = mutableListOf<Check>()
        val t = pose.torsoLength
        val k = ServeAnalyzer.kneeAngle(pose)
        checks += if (k != null) {
            val status = ServeAnalyzer.band(k, 120.0..165.0, 105.0..172.0)
            Check("ready-knees", "Knees bent", status, ServeAnalyzer.deg(k),
                if (status == Status.GOOD) "Nice athletic stance." else if (k > 165) "Bend your knees a little more so you can push off in any direction."
                else "That's very low — a moderate knee bend lets you move faster.")
        } else ServeAnalyzer.unknown("ready-knees", "Knees bent")

        val w = stanceWidth(pose)
        checks += if (w != null) {
            val status = if (w >= 0.9) Status.GOOD else if (w >= 0.6) Status.WARN else Status.BAD
            Check("ready-stance", "Feet wider than shoulders", status, ServeAnalyzer.torso(w),
                if (status == Status.GOOD) "Good wide base." else "Widen your stance — feet a bit more than shoulder-width apart.")
        } else ServeAnalyzer.unknown("ready-stance", "Feet wider than shoulders")

        val hip = hipMid(pose)
        val lw = pose[Joint.LEFT_WRIST]
        val rw = pose[Joint.RIGHT_WRIST]
        checks += if (hip != null && t != null && lw != null && rw != null) {
            val up = listOf(lw, rw).count { (hip.y - it.y) / t >= 0.1 }
            val status = if (up == 2) Status.GOOD else if (up == 1) Status.WARN else Status.BAD
            Check("ready-hands", "Racket up in front", status, "$up of 2 hands up",
                if (status == Status.GOOD) "Racket ready in front of you." else "Hold the racket up in front of you with both hands, above your waist.")
        } else ServeAnalyzer.unknown("ready-hands", "Racket up in front")
        return Evaluation(Phase.READY, checks)
    }

    // Groundstrokes and volleys

    internal fun preparation(type: StrokeType, pose: Pose, hand: Handedness, d: Double): Evaluation {
        val checks = mutableListOf<Check>()
        val volley = type == StrokeType.VOLLEY
        val b = backswingDistance(pose, hand, d)
        checks += when {
            b == null -> ServeAnalyzer.unknown(if (volley) "volley-compact" else "prep-takeback", if (volley) "Compact backswing" else "Racket taken back")
            volley -> {
                val status = if (b <= 0.4) Status.GOOD else if (b <= 0.7) Status.WARN else Status.BAD
                Check("volley-compact", "Compact backswing", status, ServeAnalyzer.torso(b),
                    if (status == Status.GOOD) "Nice short preparation." else "Keep the backswing short — just turn your shoulders and catch the ball in front.")
            }
            else -> {
                val status = if (b >= 0.5) Status.GOOD else if (b >= 0.25) Status.WARN else Status.BAD
                Check("prep-takeback", "Racket taken back", status, ServeAnalyzer.torso(b),
                    if (status == Status.GOOD) "Good early take-back." else "Turn and take the racket back early, before the ball bounces.")
            }
        }

        val k = ServeAnalyzer.kneeAngle(pose)
        checks += if (k != null) {
            val status = ServeAnalyzer.band(k, 110.0..160.0, 95.0..170.0)
            Check("prep-knees", "Knees bent", status, ServeAnalyzer.deg(k),
                if (status == Status.GOOD) "Loaded and ready to push into the shot." else if (k > 160) "Bend your knees as you turn so you can push up into the shot."
                else "That's very low — a moderate bend keeps you balanced.")
        } else ServeAnalyzer.unknown("prep-knees", "Knees bent")

        if (volley) {
            val w = hitWrist(pose, hand)
            val hip = hipMid(pose)
            val t = pose.torsoLength
            checks += if (w != null && hip != null && t != null) {
                val h = (hip.y - w.y) / t
                val status = if (h >= 0.3) Status.GOOD else if (h >= 0) Status.WARN else Status.BAD
                Check("volley-hands-up", "Racket head up", status, ServeAnalyzer.torso(h),
                    if (status == Status.GOOD) "Racket up and ready." else "Keep the racket up in front of you, not dropping below your waist.")
            } else ServeAnalyzer.unknown("volley-hands-up", "Racket head up")
        } else {
            val w = stanceWidth(pose)
            checks += if (w != null) {
                val status = if (w >= 0.9) Status.GOOD else if (w >= 0.6) Status.WARN else Status.BAD
                Check("prep-stance", "Wide, stable stance", status, ServeAnalyzer.torso(w),
                    if (status == Status.GOOD) "Solid base." else "Widen your stance — step out so your feet are wider than your shoulders.")
            } else ServeAnalyzer.unknown("prep-stance", "Wide, stable stance")
        }

        if (type == StrokeType.FOREHAND) {
            val w = tossWrist(pose, hand)
            val sm = shoulderMid(pose)
            val t = pose.torsoLength
            checks += if (w != null && sm != null && t != null) {
                val f = (w.x - sm.x) * d / t
                val status = if (f >= 0.15) Status.GOOD else if (f >= -0.1) Status.WARN else Status.BAD
                Check("prep-off-arm", "Non-hitting arm out in front", status, ServeAnalyzer.torso(f),
                    if (status == Status.GOOD) "Off-arm helping the turn." else "Point your non-hitting hand toward the ball as you turn — it sets up the shoulder turn.")
            } else ServeAnalyzer.unknown("prep-off-arm", "Non-hitting arm out in front")
        }
        return Evaluation(Phase.PREPARATION, checks)
    }

    internal fun groundContact(type: StrokeType, pose: Pose, hand: Handedness, d: Double, twoHanded: Boolean): Evaluation {
        val checks = mutableListOf<Check>()
        val (hit, _) = pose.sides(hand)
        val t = pose.torsoLength
        val hip = hipMid(pose)

        checks += if (hit.wrist != null && hip != null && t != null) {
            val f = (hit.wrist.x - hip.x) * d / t
            val good = if (type == StrokeType.VOLLEY) 0.3 else 0.2
            val status = if (f >= good) Status.GOOD else if (f >= -0.05) Status.WARN else Status.BAD
            Check("contact-in-front", "Contact out in front", status, ServeAnalyzer.torso(f),
                if (status == Status.GOOD) "Great — you met the ball in front." else "Meet the ball out in front of your front hip, not beside you.")
        } else ServeAnalyzer.unknown("contact-in-front", "Contact out in front")

        if (!(type == StrokeType.BACKHAND && twoHanded)) {
            checks += if (hit.shoulder != null && hit.elbow != null && hit.wrist != null) {
                val a = Geometry.angle(hit.shoulder, hit.elbow, hit.wrist)
                when (type) {
                    StrokeType.VOLLEY -> {
                        val status = ServeAnalyzer.band(a, 100.0..170.0, 80.0..180.0)
                        Check("volley-firm", "Firm arm at contact", status, ServeAnalyzer.deg(a),
                            if (status == Status.GOOD) "Firm, compact contact." else "Keep a firm, slightly bent arm and punch the ball — don't swing at it.")
                    }
                    StrokeType.BACKHAND -> {
                        val status = ServeAnalyzer.band(a, 150.0..180.0, 130.0..180.0)
                        Check("contact-spacing", "Arm extended at contact", status, ServeAnalyzer.deg(a),
                            if (status == Status.GOOD) "Good extension through the ball." else "On a one-handed backhand, hit with a straight arm — give yourself more room.")
                    }
                    else -> {
                        val status = ServeAnalyzer.band(a, 110.0..180.0, 90.0..180.0)
                        Check("contact-spacing", "Room between you and the ball", status, ServeAnalyzer.deg(a),
                            if (status == Status.GOOD) "Good spacing." else "You're jammed — leave about an arm's length between you and the ball.")
                    }
                }
            } else ServeAnalyzer.unknown(if (type == StrokeType.VOLLEY) "volley-firm" else "contact-spacing", "Arm at contact")
        }

        if (type != StrokeType.VOLLEY) {
            checks += if (hit.wrist != null && hip != null && t != null) {
                val h = (hip.y - hit.wrist.y) / t
                val status = ServeAnalyzer.band(h, -0.3..0.9, -0.6..1.2)
                Check("strike-zone", "Contact between waist and chest", status, ServeAnalyzer.torso(h),
                    if (status == Status.GOOD) "Right in your strike zone." else if (h > 0.9) "Move back so you don't have to hit at shoulder height or above."
                    else "Bend your knees to get down to low balls instead of reaching with the racket.")
            } else ServeAnalyzer.unknown("strike-zone", "Contact between waist and chest")
        }

        checks += balance(pose, "contact-balance", "Balanced at contact",
            "Stay tall and balanced through contact — let your legs, not your back, lower you.")
        return Evaluation(Phase.CONTACT, checks)
    }

    internal fun finish(type: StrokeType, pose: Pose, hand: Handedness, swingPath: Double): Evaluation {
        val checks = mutableListOf<Check>()
        if (type == StrokeType.VOLLEY) {
            val status = if (swingPath <= 1.2) Status.GOOD else if (swingPath <= 1.8) Status.WARN else Status.BAD
            checks += Check("volley-short", "Short follow-through", status, ServeAnalyzer.torso(swingPath),
                if (status == Status.GOOD) "Punch and stop — nicely done." else "Punch and stop — a volley needs very little follow-through.")
        } else {
            val w = hitWrist(pose, hand)
            val sm = shoulderMid(pose)
            val t = pose.torsoLength
            checks += if (w != null && sm != null && t != null) {
                val h = (sm.y - w.y) / t
                val status = if (h >= 0) Status.GOOD else if (h >= -0.5) Status.WARN else Status.BAD
                Check("finish-high", "High finish", status, ServeAnalyzer.torso(h),
                    if (status == Status.GOOD) "Nice high finish." else "Swing up and finish high, over your shoulder.")
            } else ServeAnalyzer.unknown("finish-high", "High finish")
            val status = if (swingPath >= 2.0) Status.GOOD else if (swingPath >= 1.3) Status.WARN else Status.BAD
            checks += Check("finish-through", "Full swing through the ball", status, ServeAnalyzer.torso(swingPath),
                if (status == Status.GOOD) "Full, relaxed swing." else "Swing all the way through the ball instead of stopping at contact.")
        }
        checks += balance(pose, "finish-balance", "Balanced finish", "Hold your finish for a second — if you can't, you were off balance.")
        return Evaluation(Phase.FINISH, checks)
    }

    // Overhead

    internal fun overheadPreparation(pose: Pose, hand: Handedness): Evaluation {
        val checks = mutableListOf<Check>()
        val (hit, toss) = pose.sides(hand)
        val t = pose.torsoLength
        val nose = pose[Joint.NOSE]
        checks += if (toss.wrist != null && nose != null && t != null) {
            val h = (nose.y - toss.wrist.y) / t
            val status = if (h >= 0.3) Status.GOOD else if (h >= 0) Status.WARN else Status.BAD
            Check("oh-off-arm-up", "Non-hitting hand pointing up", status, ServeAnalyzer.torso(h),
                if (status == Status.GOOD) "Good — tracking the ball with your hand." else "Point your non-hitting hand up at the ball to line it up.")
        } else ServeAnalyzer.unknown("oh-off-arm-up", "Non-hitting hand pointing up")

        checks += if (hit.shoulder != null && hit.elbow != null && t != null) {
            val drop = (hit.elbow.y - hit.shoulder.y) / t
            val status = if (drop <= 0.1) Status.GOOD else if (drop <= 0.3) Status.WARN else Status.BAD
            Check("oh-racket-up", "Racket up early", status, if (drop <= 0) "above" else "${ServeAnalyzer.torso(drop)} below",
                if (status == Status.GOOD) "Racket up and ready." else "Get the racket up behind your head early, elbow at shoulder height.")
        } else ServeAnalyzer.unknown("oh-racket-up", "Racket up early")

        val k = ServeAnalyzer.kneeAngle(pose)
        checks += if (k != null) {
            val status = ServeAnalyzer.band(k, 110.0..165.0, 95.0..172.0)
            Check("prep-knees", "Knees bent", status, ServeAnalyzer.deg(k),
                if (status == Status.GOOD) "Loaded and ready." else "Bend your knees so you can push up to the ball.")
        } else ServeAnalyzer.unknown("prep-knees", "Knees bent")
        return Evaluation(Phase.PREPARATION, checks)
    }

    internal fun overheadContact(pose: Pose, hand: Handedness): Evaluation {
        val checks = mutableListOf<Check>()
        val (hit, _) = pose.sides(hand)
        checks += if (hit.shoulder != null && hit.elbow != null && hit.wrist != null) {
            val a = Geometry.angle(hit.shoulder, hit.elbow, hit.wrist)
            val status = ServeAnalyzer.band(a, 155.0..180.0, 140.0..180.0)
            Check("hit-arm-extended", "Hitting arm fully extended", status, ServeAnalyzer.deg(a),
                if (status == Status.GOOD) "Full reach at contact." else "Reach up and hit at full extension — move back so the ball doesn't drop on you.")
        } else ServeAnalyzer.unknown("hit-arm-extended", "Hitting arm fully extended")

        val nose = pose[Joint.NOSE]
        val t = pose.torsoLength
        checks += if (hit.wrist != null && nose != null && t != null) {
            val h = (nose.y - hit.wrist.y) / t
            val status = if (h >= 0.7) Status.GOOD else if (h >= 0.4) Status.WARN else Status.BAD
            Check("oh-contact-high", "Contact high and in front", status, ServeAnalyzer.torso(h),
                if (status == Status.GOOD) "Hit at the top of your reach." else "Take quick steps back so you can hit the ball at the top of your reach.")
        } else ServeAnalyzer.unknown("oh-contact-high", "Contact high and in front")

        checks += balance(pose, "contact-balance", "Balanced at contact",
            "Stay tall — falling backwards usually means you didn't get far enough behind the ball.")
        return Evaluation(Phase.CONTACT, checks)
    }

    // Helpers

    internal fun balance(pose: Pose, id: String, label: String, tip: String): Check {
        val ls = pose[Joint.LEFT_SHOULDER]
        val rs = pose[Joint.RIGHT_SHOULDER]
        val lh = pose[Joint.LEFT_HIP]
        val rh = pose[Joint.RIGHT_HIP]
        if (ls == null || rs == null || lh == null || rh == null) return ServeAnalyzer.unknown(id, label)
        val lean = Geometry.leanFromVertical(Geometry.midpoint(lh, rh), Geometry.midpoint(ls, rs))
        val status = ServeAnalyzer.band(lean, 0.0..20.0, 0.0..30.0)
        return Check(id, label, status, ServeAnalyzer.deg(lean), if (status == Status.GOOD) "Well balanced." else tip)
    }

    internal fun hitShoulder(hand: Handedness) = if (hand == Handedness.RIGHT) Joint.RIGHT_SHOULDER else Joint.LEFT_SHOULDER
    internal fun tossShoulder(hand: Handedness) = if (hand == Handedness.RIGHT) Joint.LEFT_SHOULDER else Joint.RIGHT_SHOULDER
    internal fun hitWrist(p: Pose, hand: Handedness) = p[if (hand == Handedness.RIGHT) Joint.RIGHT_WRIST else Joint.LEFT_WRIST]
    internal fun tossWrist(p: Pose, hand: Handedness) = p[if (hand == Handedness.RIGHT) Joint.LEFT_WRIST else Joint.RIGHT_WRIST]

    internal fun hipMid(p: Pose): Point? {
        val l = p[Joint.LEFT_HIP] ?: return null
        val r = p[Joint.RIGHT_HIP] ?: return null
        return Geometry.midpoint(l, r)
    }

    internal fun shoulderMid(p: Pose): Point? {
        val l = p[Joint.LEFT_SHOULDER] ?: return null
        val r = p[Joint.RIGHT_SHOULDER] ?: return null
        return Geometry.midpoint(l, r)
    }

    internal fun stanceWidth(p: Pose): Double? {
        val l = p[Joint.LEFT_ANKLE] ?: return null
        val r = p[Joint.RIGHT_ANKLE] ?: return null
        val t = p.torsoLength ?: return null
        return Geometry.distance(l, r) / t
    }

    /** Height of [point] above the nose, in torso lengths (-infinity when unknown). */
    internal fun height(point: Point?, f: Frame): Double {
        val nose = f.pose[Joint.NOSE]
        val t = f.pose.torsoLength
        if (point == null || nose == null || t == null) return Double.NEGATIVE_INFINITY
        return (nose.y - point.y) / t
    }

    /** How far the hitting hand is behind the shoulders, against the swing direction [d] (+1 or -1). */
    internal fun backswingDistance(p: Pose, hand: Handedness, d: Double): Double? {
        val w = hitWrist(p, hand) ?: return null
        val sm = shoulderMid(p) ?: return null
        val t = p.torsoLength ?: return null
        return -(w.x - sm.x) * d / t
    }

    internal fun medianTorso(frames: List<Frame>): Double? {
        val lengths = frames.mapNotNull { it.pose.torsoLength }.sorted()
        return if (lengths.isEmpty()) null else lengths[lengths.size / 2]
    }

    internal fun pathLength(points: List<Point>) = points.zipWithNext { a, b -> Geometry.distance(a, b) }.sum()

    /** +1 when the hitting hand moves right through contact, -1 when it moves left. */
    internal fun swingDirection(frames: List<Frame>, event: SwingEvent, hand: Handedness): Double {
        val a = hitWrist(frames[max(0, event.index - 1)].pose, hand) ?: return 1.0
        val b = hitWrist(frames[min(frames.size - 1, event.index + 1)].pose, hand) ?: return 1.0
        return if (b.x >= a.x) 1.0 else -1.0
    }

    /** The moment of fullest backswing before contact. */
    internal fun preparationFrame(frames: List<Frame>, event: SwingEvent, hand: Handedness, d: Double): Frame? =
        frames.filter { it.time >= event.time - 1.2 && it.time <= event.time - 0.08 }
            .mapNotNull { f -> backswingDistance(f.pose, hand, d)?.let { f to it } }
            .maxByOrNull { it.second }?.first

    /** The finish: highest hand after a groundstroke, or the end of the punch on a volley. */
    internal fun finishFrame(frames: List<Frame>, event: SwingEvent, hand: Handedness, volley: Boolean): Frame? {
        if (volley) {
            return frames.filter { it.time >= event.time + 0.1 && it.time <= event.time + 0.6 && hitWrist(it.pose, hand) != null }
                .minByOrNull { abs(it.time - event.time - 0.35) }
        }
        return frames.filter { it.time >= event.time + 0.08 && it.time <= event.time + 1.0 }
            .mapNotNull { f -> hitWrist(f.pose, hand)?.let { f to it.y } }
            .minByOrNull { it.second }?.first
    }
}

/**
 * Watches a live stream of poses and reports each groundstroke, volley or overhead about a
 * second after it's hit (once the finish has been seen). Use [ServeTracker] for serves.
 */
class StrokeTracker(val hand: Handedness, /** The stroke being practised, or null to work it out. */ val type: StrokeType?) {
    private val buffer = ArrayDeque<Frame>()
    private var lastReported = Double.NEGATIVE_INFINITY

    fun add(frame: Frame): StrokeResult? {
        buffer.addLast(frame)
        while (buffer.first().time < frame.time - 3.5) buffer.removeFirst()
        val frames = buffer.toList()
        val swing = StrokeAnalyzer.swings(frames, hand).firstOrNull { it.time > lastReported + 0.5 && frame.time - it.time >= 1.0 } ?: return null
        lastReported = swing.time
        return StrokeAnalyzer.analyze(frames, swing, type, hand)
    }
}
