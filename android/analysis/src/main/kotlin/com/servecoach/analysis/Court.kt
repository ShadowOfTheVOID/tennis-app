package com.servecoach.analysis

import kotlin.math.abs
import kotlin.math.max


/** A projective map between two planes, from four point pairs. Mirrors `Homography` in Swift. */
class Homography private constructor(private val h: DoubleArray, private val ox: Double, private val oy: Double) {
    fun map(px: Double, py: Double): Pair<Double, Double>? {
        val x = px - ox
        val y = py - oy
        val w = h[6] * x + h[7] * y + 1
        if (abs(w) < 1e-12) return null
        return (h[0] * x + h[1] * y + h[2]) / w to (h[3] * x + h[4] * y + h[5]) / w
    }

    companion object {
        /** The map taking each of [from] to the matching point of [to]. Null if the points are degenerate. */
        fun fit(from: List<Pair<Double, Double>>, to: List<Pair<Double, Double>>): Homography? {
            require(from.size == 4 && to.size == 4)
            // Solved about the points' centroid, which lies inside the shape and so is never on the horizon
            // (where the usual normalisation would break down).
            val ox = from.sumOf { it.first } / 4
            val oy = from.sumOf { it.second } / 4
            val a = Array(8) { DoubleArray(9) }
            for (i in 0 until 4) {
                val x = from[i].first - ox
                val y = from[i].second - oy
                val (u, v) = to[i]
                a[2 * i] = doubleArrayOf(x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y, u)
                a[2 * i + 1] = doubleArrayOf(0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y, v)
            }
            // Gaussian elimination with partial pivoting.
            for (col in 0 until 8) {
                val pivot = (col until 8).maxBy { abs(a[it][col]) }
                if (abs(a[pivot][col]) < 1e-12) return null
                val t = a[col]; a[col] = a[pivot]; a[pivot] = t
                for (r in 0 until 8) {
                    if (r == col) continue
                    val f = a[r][col] / a[col][col]
                    if (f != 0.0) for (c in col..8) a[r][c] -= f * a[col][c]
                }
            }
            return Homography(DoubleArray(8) { a[it][8] / a[it][it] }, ox, oy)
        }
    }
}

/** Singles court in metres: x across (0 to [WIDTH]), y along (0 to [LENGTH]), net at [NET]. */
object Court {
    const val WIDTH = 8.23
    const val LENGTH = 23.77
    const val NET = LENGTH / 2
    /** Service line distance from the net. */
    const val SERVICE = 6.40
    /** Lines count as in; this allows for their 5 cm width. */
    const val LINE = 0.05

    /** The four corners in tap order: both ends of one baseline, then around the court. */
    val corners = listOf(0.0 to 0.0, WIDTH to 0.0, WIDTH to LENGTH, 0.0 to LENGTH)

    /** Image-to-court map from the four tapped corners (any image units). Null if they don't form a convex shape. */
    fun calibrate(taps: List<Pair<Double, Double>>): Homography? {
        if (taps.size != 4 || !convex(taps)) return null
        return Homography.fit(taps, corners)
    }

    internal fun convex(p: List<Pair<Double, Double>>): Boolean {
        var sign = 0
        for (i in 0 until 4) {
            val (ax, ay) = p[i]; val (bx, by) = p[(i + 1) % 4]; val (cx, cy) = p[(i + 2) % 4]
            val cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx)
            if (abs(cross) < 1e-9) return false
            val s = if (cross > 0) 1 else -1
            if (sign == 0) sign = s else if (s != sign) return false
        }
        return true
    }
}

enum class Depth(val title: String) { SHORT("Short"), MID("Middle"), DEEP("Deep") }

/** Where a bounce landed, in court metres. */
data class Bounce(val time: Double, val x: Double, val y: Double) {
    val isIn: Boolean get() = x >= -Court.LINE && x <= Court.WIDTH + Court.LINE && y >= -Court.LINE && y <= Court.LENGTH + Court.LINE
    /** 0 for the half nearer y = 0, 1 for the other. */
    val half: Int get() = if (y < Court.NET) 0 else 1
    val long: Boolean get() = y < -Court.LINE || y > Court.LENGTH + Court.LINE
    val wide: Boolean get() = x < -Court.LINE || x > Court.WIDTH + Court.LINE
    val depth: Depth
        get() {
            val fromNet = abs(y - Court.NET)
            return when {
                fromNet <= Court.SERVICE -> Depth.SHORT
                fromNet >= Court.NET - 3 -> Depth.DEEP
                else -> Depth.MID
            }
        }
}

/** Your shots' landing spots, and what they add up to. */
data class Placement(val yours: List<Bounce>, val theirs: List<Bounce>) {
    val inRate: Double? get() = if (yours.isEmpty()) null else yours.count { it.isIn }.toDouble() / yours.size
    val long: Int get() = yours.count { it.long }
    val wide: Int get() = yours.count { it.wide && !it.long }
    private val landed get() = yours.filter { it.isIn }
    fun depthRate(depth: Depth): Double? = landed.takeIf { it.isNotEmpty() }?.let { l -> l.count { it.depth == depth }.toDouble() / l.size }

    val tip: String?
        get() {
            val rate = inRate ?: return null
            val deep = depthRate(Depth.DEEP) ?: 0.0
            val short = depthRate(Depth.SHORT) ?: 0.0
            return when {
                rate < 0.6 && long > wide -> "Many shots go long. Swing low to high with more topspin, and aim a metre or two inside the baseline."
                rate < 0.6 -> "Many shots go wide. Aim further inside the sidelines; go for the lines only on an easy ball."
                short > 0.4 -> "Lots of your shots land short, which lets your opponent attack. Aim past the service line, about two metres from the baseline."
                deep >= 0.4 -> "Good depth: plenty of your shots land in the last 3 metres."
                else -> "Mostly safe, middling depth. Aim a little deeper to push your opponent back."
            }
        }
}

/** Bounces from the ball track, mapped onto the court. Mirrors `CourtAnalysis` in Swift. */
object CourtAnalysis {
    /**
     * Bounces are where the ball, seen as fractions of the image, stops falling and starts rising
     * while still travelling the same way across the frame (a hit would reverse it).
     */
    fun bounces(sightings: List<BallSighting>, maxStep: Double = 0.1): List<BallSighting> {
        val out = mutableListOf<BallSighting>()
        for (i in 2 until sightings.size - 2) {
            val w = sightings.subList(i - 2, i + 3)
            if ((1 until w.size).any { w[it].time - w[it - 1].time > maxStep }) continue
            val b = w[2]
            if (w.any { it.y > b.y }) continue
            if (b.y - w[0].y < 0.01 || b.y - w[4].y < 0.005) continue
            val before = b.x - w[0].x
            val after = w[4].x - b.x
            if (before * after < 0 && max(abs(before), abs(after)) > 0.01) continue
            if (out.lastOrNull()?.let { b.time - it.time < 0.2 } == true) continue
            out += b
        }
        return out
    }

    /**
     * Your shots land on the other half from where you stand. [playerSpots] are your feet as image
     * fractions during the match; [court] maps image fractions to court metres.
     */
    fun placement(sightings: List<BallSighting>, court: Homography, playerSpots: List<Pair<Double, Double>>): Placement {
        val halves = playerSpots.mapNotNull { (x, y) -> court.map(x, y)?.second }.map { if (it < Court.NET) 0 else 1 }
        val yourHalf = if (halves.count { it == 1 } > halves.size / 2) 1 else 0
        val all = bounces(sightings).mapNotNull { b -> court.map(b.x, b.y)?.let { (x, y) -> Bounce(b.time, x, y) } }
            // Anything far off the court is a misreading, not a bounce.
            .filter { it.x in -6.0..(Court.WIDTH + 6) && it.y in -8.0..(Court.LENGTH + 8) }
        return Placement(yours = all.filter { it.half != yourHalf }, theirs = all.filter { it.half == yourHalf })
    }

    /** Midpoint of the ankles, as image fractions, for [placement]. */
    fun feet(pose: Pose, width: Double, height: Double): Pair<Double, Double>? {
        val l = pose[Joint.LEFT_ANKLE] ?: return null
        val r = pose[Joint.RIGHT_ANKLE] ?: return null
        return (l.x + r.x) / 2 / width to max(l.y, r.y) / height
    }

}
