package com.servecoach.analysis

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** A small RGB image (3 bytes per pixel, row-major) for ball detection. */
class RgbImage(val width: Int, val height: Int, val rgb: ByteArray, val time: Double)

/** A ball sighting, as fractions of the image width and height (0–1, y down). */
data class BallSighting(val time: Double, val x: Double, val y: Double)

/**
 * Finds a moving tennis ball: optic-yellow pixels, grouped into small blobs that moved since the
 * previous frame (so yellow signs, shirts standing still and the like are ignored).
 * Mirrors `BallDetector` in Swift.
 */
object BallDetector {
    internal data class Blob(val x: Double, val y: Double, val area: Int, val moved: Double)

    /** Optic yellow: hue 45–95°, fairly saturated and bright. */
    fun isBallColour(r: Int, g: Int, b: Int): Boolean {
        val hi = max(r, max(g, b))
        val lo = min(r, min(g, b))
        if (hi < 110 || hi - lo < 0.35 * hi) return false
        val d = (hi - lo).toDouble()
        val hue = when (hi) {
            r -> 60 * (((g - b) / d) % 6)
            g -> 60 * ((b - r) / d + 2)
            else -> 60 * ((r - g) / d + 4)
        }.let { if (it < 0) it + 360 else it }
        return hue in 45.0..95.0
    }

    internal fun blobs(image: RgbImage, previous: RgbImage?): List<Blob> {
        if (previous == null || previous.width != image.width || previous.height != image.height) return emptyList()
        val w = image.width
        val h = image.height
        val px = image.rgb
        val mask = BooleanArray(w * h) { i ->
            isBallColour(px[3 * i].toInt() and 0xFF, px[3 * i + 1].toInt() and 0xFF, px[3 * i + 2].toInt() and 0xFF)
        }
        val maxArea = max(12, w * h / 800)
        val seen = BooleanArray(w * h)
        val stack = IntArray(w * h)
        val out = mutableListOf<Blob>()
        for (start in 0 until w * h) {
            if (!mask[start] || seen[start]) continue
            var top = 0
            stack[top++] = start
            seen[start] = true
            var area = 0; var sx = 0.0; var sy = 0.0; var moved = 0
            var minX = w; var maxX = 0; var minY = h; var maxY = 0
            while (top > 0) {
                val i = stack[--top]
                val x = i % w
                val y = i / w
                area++; sx += x; sy += y
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if (changed(px, previous.rgb, i)) moved++
                for (dy in -1..1) for (dx in -1..1) {
                    val nx = x + dx
                    val ny = y + dy
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                    val j = ny * w + nx
                    if (mask[j] && !seen[j]) { seen[j] = true; stack[top++] = j }
                }
            }
            if (area < 2 || area > maxArea || moved == 0) continue
            // A ball, even motion-blurred, fills a fair part of its bounding box.
            val box = (maxX - minX + 1) * (maxY - minY + 1)
            if (area < 0.3 * box) continue
            out += Blob((sx / area + 0.5) / w, (sy / area + 0.5) / h, area, moved.toDouble() / area)
        }
        return out
    }

    private fun changed(a: ByteArray, b: ByteArray, i: Int): Boolean {
        var most = 0
        for (c in 0..2) most = max(most, abs((a[3 * i + c].toInt() and 0xFF) - (b[3 * i + c].toInt() and 0xFF)))
        return most > 40
    }
}

/**
 * Follows the ball from frame to frame with a constant-velocity guess, and only reports it once
 * it has been seen on three frames in a row that line up. Mirrors `BallTracker` in Swift.
 */
class BallTracker(private val maxGap: Double = 0.3) {
    private var previous: RgbImage? = null
    private val track = mutableListOf<BallSighting>()
    private val _sightings = mutableListOf<BallSighting>()
    val sightings: List<BallSighting> get() = _sightings

    fun add(image: RgbImage): BallSighting? {
        val blobs = BallDetector.blobs(image, previous)
        previous = image
        track.lastOrNull()?.let { if (image.time - it.time > maxGap) track.clear() }
        val pick = choose(blobs, image.time)
        if (pick == null) {
            if (track.size < CONFIRM) track.clear()
            return null
        }
        track += pick
        when {
            track.size == CONFIRM -> _sightings += track
            track.size > CONFIRM -> _sightings += pick
            else -> return null
        }
        return pick
    }

    private fun choose(blobs: List<BallDetector.Blob>, time: Double): BallSighting? {
        if (blobs.isEmpty()) return null
        val last = track.lastOrNull()
            ?: return blobs.maxBy { it.moved * sqrt(it.area.toDouble()) }.let { BallSighting(time, it.x, it.y) }
        var px = last.x
        var py = last.y
        var gate = 0.12
        if (track.size >= 2) {
            val before = track[track.size - 2]
            val dt = last.time - before.time
            if (dt > 0) {
                val vx = (last.x - before.x) / dt
                val vy = (last.y - before.y) / dt
                px += vx * (time - last.time)
                py += vy * (time - last.time)
                gate = max(gate, hypot(vx, vy) * (time - last.time))
            }
        }
        val best = blobs.minBy { hypot(it.x - px, it.y - py) }
        return if (hypot(best.x - px, best.y - py) <= gate) BallSighting(time, best.x, best.y) else null
    }

    companion object {
        const val CONFIRM = 3
    }
}

/** Where the toss peaked, relative to the server, in torso lengths. */
data class TossReading(
    /** Above the head (nose); positive is higher. */
    val height: Double,
    /** In front of the hitting shoulder, toward the court; negative is behind. */
    val forward: Double,
) {
    val tip: String
        get() = when {
            forward < 0 -> "Your toss drifts behind you. Toss a little more into the court so you can move up into it."
            forward > 1.5 -> "Your toss is far in front. Toss closer, about a racket's width in front of your hitting shoulder."
            height < 0.8 -> "Toss higher, so the ball peaks above your full reach and you can hit up to it."
            height > 2.5 -> "Your toss is very high, which makes timing hard. Toss a little lower."
            else -> "Good toss: in front of you and high enough to reach up to."
        }
}

/** How consistent the toss is over several serves. */
data class TossConsistency(val average: TossReading, /** Average distance from the average peak, in torso lengths. */ val spread: Double, val count: Int) {
    val verdict: String get() = when {
        spread <= 0.25 -> "Very consistent toss"
        spread <= 0.5 -> "Fairly consistent toss"
        else -> "Your toss moves around a lot"
    }
}

/** A run of play with the ball in sight, and how many times it changed direction (about one per shot). */
data class Rally(val start: Double, val end: Double, val shots: Int)

/** Ball-based readings: toss placement for serves, and rallies. Mirrors `BallAnalysis` in Swift. */
object BallAnalysis {
    /**
     * Where the toss peaked for a serve, from ball sightings and the serve's trophy pose.
     * [width] and [height] are the pose image's size in pixels.
     */
    fun toss(sightings: List<BallSighting>, serve: StrokeResult, hand: Handedness, width: Double, height: Double): TossReading? {
        if (serve.type != StrokeType.SERVE) return null
        val trophy = serve.frame(Phase.TROPHY) ?: return null
        val contact = serve.frame(Phase.CONTACT) ?: return null
        val pose = trophy.pose
        val torso = pose.torsoLength ?: return null
        val nose = pose[Joint.NOSE] ?: return null
        val shoulder = pose[if (hand == Handedness.RIGHT) Joint.RIGHT_SHOULDER else Joint.LEFT_SHOULDER] ?: return null
        val inFlight = sightings.filter { it.time in (trophy.time - 1.2)..contact.time }
        if (inFlight.size < 3) return null
        val apex = inFlight.minBy { it.y }
        return TossReading(
            height = (nose.y - apex.y * height) / torso,
            forward = (apex.x * width - shoulder.x) * serve.direction / torso,
        )
    }

    fun consistency(tosses: List<TossReading>): TossConsistency? {
        if (tosses.size < 3) return null
        val h = tosses.sumOf { it.height } / tosses.size
        val f = tosses.sumOf { it.forward } / tosses.size
        val spread = tosses.sumOf { hypot(it.height - h, it.forward - f) } / tosses.size
        return TossConsistency(TossReading(h, f), spread, tosses.size)
    }

    /**
     * Splits sightings into rallies (gaps over [maxGap] seconds end one) and counts direction changes
     * across the frame, each after at least [minTravel] of the frame width.
     */
    fun rallies(sightings: List<BallSighting>, maxGap: Double = 1.5, minTravel: Double = 0.15): List<Rally> {
        val out = mutableListOf<Rally>()
        var i = 0
        while (i < sightings.size) {
            var j = i
            while (j + 1 < sightings.size && sightings[j + 1].time - sightings[j].time <= maxGap) j++
            val run = sightings.subList(i, j + 1)
            // The first long move is the first shot; every reversal after that is another.
            var shots = 0
            var direction = 0
            var extreme = run.first().x
            for (s in run.drop(1)) {
                if (direction == 0) {
                    if (abs(s.x - extreme) >= minTravel) { direction = if (s.x > extreme) 1 else -1; shots = 1; extreme = s.x }
                } else if ((s.x - extreme) * direction > 0) {
                    extreme = s.x
                } else if ((extreme - s.x) * direction >= minTravel) {
                    direction = -direction; shots++; extreme = s.x
                }
            }
            if (shots > 0) out += Rally(run.first().time, run.last().time, shots)
            i = j + 1
        }
        return out
    }
}
