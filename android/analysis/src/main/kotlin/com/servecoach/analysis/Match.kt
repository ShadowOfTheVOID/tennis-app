package com.servecoach.analysis

import kotlin.math.abs

/** How one kind of stroke went across a match. */
data class StrokeSummary(
    val type: StrokeType,
    val count: Int,
    val averageScore: Int?,
    /** The check that most often needed work, if any. */
    val commonFix: Check?,
)

/** Everything learned from a match or rally video. Mirrors `MatchReport` in the Swift package. */
data class MatchReport(
    /** Length of the analysed video, in seconds. */
    val duration: Double,
    val strokes: List<StrokeResult>,
    /** Points or rallies, split by serves and long pauses. */
    val rallies: Int,
    /** Share of groundstrokes and volleys preceded by a split step (null if none to judge). */
    val splitStepRate: Double?,
    /** Share of the time between shots spent in an athletic stance with knees bent. */
    val readyStanceRate: Double?,
    /** Approximate side-to-side distance covered, in metres (movement toward the camera isn't seen). */
    val movementMeters: Double?,
) {
    val summaries: List<StrokeSummary>
        get() = StrokeType.entries.mapNotNull { type ->
            val group = strokes.filter { it.type == type }
            if (group.isEmpty()) return@mapNotNull null
            val scores = group.mapNotNull { it.score }
            val fixes = group.mapNotNull { it.topTip }
            // Most frequent fix; ties go to the alphabetically first id, as in Swift.
            val top = fixes.groupingBy { it.id }.eachCount().entries
                .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .firstOrNull()?.key
            StrokeSummary(type, group.size, if (scores.isEmpty()) null else scores.sum() / scores.size, fixes.firstOrNull { it.id == top })
        }

    /** "38 strokes in about 9 rallies". */
    val countsText: String
        get() = "${strokes.size} stroke${if (strokes.size == 1) "" else "s"} in about $rallies rall${if (rallies == 1) "y" else "ies"}"

    /** Average score over every stroke that could be scored. */
    val score: Int?
        get() {
            val scores = strokes.mapNotNull { it.score }
            return if (scores.isEmpty()) null else scores.sum() / scores.size
        }
}

object MatchAnalyzer {
    /** Average adult shoulder-to-hip length, used to turn torso lengths into rough metres. */
    internal const val TORSO_METERS = 0.5

    /** Find and grade every stroke the player hits in [frames], plus footwork and movement. */
    fun analyze(frames: List<Frame>, hand: Handedness): MatchReport {
        val swings = StrokeAnalyzer.swings(frames, hand)
        val scale = StrokeAnalyzer.medianTorso(frames) ?: 1.0
        val strokes = swings.map { StrokeAnalyzer.analyze(frames, it, hand = hand) }.map {
            if (it.type == StrokeType.SERVE) it else it.copy(splitStep = splitStep(frames, it.time, scale))
        }

        var rallies = 0
        var last = Double.NEGATIVE_INFINITY
        for (stroke in strokes) {
            if (stroke.type == StrokeType.SERVE || stroke.time - last > 6) rallies++
            last = stroke.time
        }

        val judged = strokes.mapNotNull { it.splitStep }
        val between = frames.filter { f -> strokes.none { abs(it.time - f.time) <= 0.8 } }
        val stances = between.mapNotNull { ServeAnalyzer.kneeAngle(it.pose) }

        return MatchReport(
            duration = (frames.lastOrNull()?.time ?: 0.0) - (frames.firstOrNull()?.time ?: 0.0),
            strokes = strokes,
            rallies = rallies,
            splitStepRate = if (judged.isEmpty()) null else judged.count { it }.toDouble() / judged.size,
            readyStanceRate = if (stances.size < 10) null else stances.count { it <= 165 }.toDouble() / stances.size,
            movementMeters = movement(frames, scale),
        )
    }

    /** A split step shows as a small hop: the feet rise briefly in the second or so before the shot. */
    internal fun splitStep(frames: List<Frame>, t: Double, scale: Double): Boolean? {
        val window = frames.filter { it.time >= t - 1.6 && it.time <= t - 0.3 }.mapNotNull { f ->
            val l = f.pose[Joint.LEFT_ANKLE] ?: return@mapNotNull null
            val r = f.pose[Joint.RIGHT_ANKLE] ?: return@mapNotNull null
            (l.y + r.y) / 2
        }
        if (window.size < 4) return null
        val sorted = window.sorted()
        return (sorted[sorted.size / 2] - sorted[0]) / scale >= 0.06
    }

    /** Side-to-side distance covered, ignoring sub-centimetre jitter. */
    internal fun movement(frames: List<Frame>, scale: Double): Double? {
        val hips = frames.mapNotNull { StrokeAnalyzer.hipMid(it.pose) }
        if (hips.size < 2) return null
        return hips.zipWithNext { a, b -> Geometry.distance(a, b) / scale }.filter { it > 0.03 }.sum() * TORSO_METERS
    }
}
